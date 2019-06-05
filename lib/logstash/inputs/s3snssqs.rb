# encoding: utf-8
require "logstash/inputs/threadable"
require "logstash/namespace"
require "logstash/timestamp"
require "logstash/plugin_mixins/aws_config"
require "logstash/errors"
require 'logstash/inputs/s3sqs/patch'
require "aws-sdk"
# "object-oriented interfaces on top of API clients"...
# => Overhead. FIXME: needed?
require "aws-sdk-resources"
require "fileutils"
# unused in code:
#require "stud/interval"
#require "digest/md5"

require 'java'
java_import java.io.InputStream
java_import java.io.InputStreamReader
java_import java.io.FileInputStream
java_import java.io.BufferedReader
java_import java.util.zip.GZIPInputStream
java_import java.util.zip.ZipException

# our helper classes
# these may go into this file for brevity...
require_relative 'sqs/poller'
require_relative 's3/client_factory'
require_relative 'log_processor'

Aws.eager_autoload!

# Get logs from AWS s3 buckets as issued by an object-created event via sqs.
#
# This plugin is based on the logstash-input-sqs plugin but doesn't log the sqs event itself.
# Instead it assumes, that the event is an s3 object-created event and will then download
# and process the given file.
#
# Some issues of logstash-input-sqs, like logstash not shutting down properly, have been
# fixed for this plugin.
#
# In contrast to logstash-input-sqs this plugin uses the "Receive Message Wait Time"
# configured for the sqs queue in question, a good value will be something like 10 seconds
# to ensure a reasonable shutdown time of logstash.
# Also use a "Default Visibility Timeout" that is high enough for log files to be downloaded
# and processed (I think a good value should be 5-10 minutes for most use cases), the plugin will
# avoid removing the event from the queue if the associated log file couldn't be correctly
# passed to the processing level of logstash (e.g. downloaded content size doesn't match sqs event).
#
# This plugin is meant for high availability setups, in contrast to logstash-input-s3 you can safely
# use multiple logstash nodes, since the usage of sqs will ensure that each logfile is processed
# only once and no file will get lost on node failure or downscaling for auto-scaling groups.
# (You should use a "Message Retention Period" >= 4 days for your sqs to ensure you can survive
# a weekend of faulty log file processing)
# The plugin will not delete objects from s3 buckets, so make sure to have a reasonable "Lifecycle"
# configured for your buckets, which should keep the files at least "Message Retention Period" days.
#
# A typical setup will contain some s3 buckets containing elb, cloudtrail or other log files.
# These will be configured to send object-created events to a sqs queue, which will be configured
# as the source queue for this plugin.
# (The plugin supports gzipped content if it is marked with "contend-encoding: gzip" as it is the
# case for cloudtrail logs)
#
# The logstash node therefore must have sqs permissions + the permissions to download objects
# from the s3 buckets that send events to the queue.
# (If logstash nodes are running on EC2 you should use a ServerRole to provide permissions)
# [source,json]
#   {
#       "Version": "2012-10-17",
#       "Statement": [
#           {
#               "Effect": "Allow",
#               "Action": [
#                   "sqs:Get*",
#                   "sqs:List*",
#                   "sqs:ReceiveMessage",
#                   "sqs:ChangeMessageVisibility*",
#                   "sqs:DeleteMessage*"
#               ],
#               "Resource": [
#                   "arn:aws:sqs:us-east-1:123456789012:my-elb-log-queue"
#               ]
#           },
#           {
#               "Effect": "Allow",
#               "Action": [
#                   "s3:Get*",
#                   "s3:List*",
#                   "s3:DeleteObject"
#               ],
#               "Resource": [
#                   "arn:aws:s3:::my-elb-logs",
#                   "arn:aws:s3:::my-elb-logs/*"
#               ]
#           }
#       ]
#   }
#
class LogStash::Inputs::S3SNSSQS < LogStash::Inputs::Threadable
  include LogStash::PluginMixins::AwsConfig::V2

  config_name "s3snssqs"

  default :codec, "plain"

  # Future config might look somewhat like this:
  #
  # s3_buckets {
  #   "bucket1_name": {
  #     "credentials": { "role": "aws:role:arn:for:bucket:access" },
  #     "folders": [
  #       {
  #         "key": "my_folder",
  #         "codec": "json"
  #         "type": "my_lovely_index"
  #       },
  #       {
  #         "key": "my_other_folder",
  #         "codec": "json_stream"
  #         "type": ""
  #       }
  #     ]
  #   },
  #   "bucket2_name": {
  #     "credentials": {
  #        "access_key_id": "some-id",
  #        "secret_access_key": "some-secret-key"
  #     },
  #     "folders": [
  #       {
  #         "key": ""
  #       }
  #     ]
  #   }
  # }
  #
  ### s3 -> TODO: replace by options for multiple buckets
  #config :s3_key_prefix, :validate => :string, :default => ''
  #Sometimes you need another key for s3. This is a first test...
  #config :s3_access_key_id, :validate => :string
  #config :s3_secret_access_key, :validate => :string
  #config :set_role_by_bucket, :validate => :hash, :default => {}
  #If you have different file-types in you s3 bucket, you could define codec by folder
  #set_codec_by_folder => {"My-ELB-logs" => "plain"}
  #config :set_codec_by_folder, :validate => :hash, :default => {}
  # The AWS IAM Role to assume, if any.
  # This is used to generate temporary credentials typically for cross-account access.
  # See https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html for more information.
  #config :s3_role_arn, :validate => :string
  # We need a list of buckets, together with role arns and possible folder/codecs:
  config :s3_options_by_bucket, :validate => hash, :required => true
  # Session name to use when assuming an IAM role
  config :s3_role_session_name, :validate => :string, :default => "logstash"

  ### sqs
  # Name of the SQS Queue to pull messages from. Note that this is just the name of the queue, not the URL or ARN.
  config :queue, :validate => :string, :required => true
  config :queue_owner_aws_account_id, :validate => :string, :required => false
  # Whether the event is processed though an SNS to SQS. (S3>SNS>SQS = true |S3>SQS=false)
  config :from_sns, :validate => :boolean, :default => true
  config :sqs_skip_delete, :validate => :boolean, :default => false
  config :delete_on_success, :validate => :boolean, :default => false
  config :visibility_timeout, :validate => :number, :default => 600

  ### system
  config :temporary_directory, :validate => :string, :default => File.join(Dir.tmpdir, "logstash")
  # To run in multiple threads use this
  config :consumer_threads, :validate => :number, :default => 1

  public

  # --- BEGIN plugin interface ----------------------------------------#

  # initialisation
  def register
    # prepare system
    FileUtils.mkdir_p(@temporary_directory) unless Dir.exist?(@temporary_directory)

    # create the bucket=>folder=>codec lookup from config options
    @codec_by_folder = {}
    @type_by_folder = {}
    @s3_options_by_bucket.each do |bucket, options|
      if options.key?('folders')
        # make these hashes do key lookups using regex matching
        folders = hash_key_is_regex({})
        types = hash_key_is_regex({})
        options['folders'].each do |entry|
          folders[entry['key']] = entry['codec'] if entry.key?('codec')
          types[entry['key']] = entry['type'] if entry.key?('type')
        end
        @codec_by_folder[bucket] = folders unless folders.empty?
        @codec_by_folder[bucket] = types unless types.empty?
      end
    end

    # instantiate helpers
    @sqs_poller = SqsPoller.new(@queue, {
      queue_owner_aws_account_id: @queue_owner_aws_account_id,
      from_sns: @from_sns,
      sqs_explicit_delete: @sqs_explicit_delete,
      visibility_timeout: @visibility_timeout
    })
    @s3_client_factory = S3ClientFactory.new({
      aws_region: @region,
      s3_options_by_bucket: @s3_options_by_bucket,
      s3_role_session_name: @s3_role_session_name
    })
    @s3_downloader = S3Downloader.new({
      temporary_directory: @temporary_directory,
      s3_client_factory: @s3_client_factory,
      delete_on_success: @delete_on_success
    })
    @codec_factory = CodecFactory.new({
      default_codec: @codec,
      codec_by_folder: @codec_by_folder
    })
    @log_processor = LogProcessor.new({
      codec_factory: @codec_factory,
      type_by_folder: @type_by_folder
    })

    # administrative stuff
    @worker_threads = []
  end

  # startup
  def run(logstash_event_queue)
    # start them
    @worker_threads = @consumer_threads.times.map do |_|
      run_worker_thread(logstash_event_queue)
    end
    # and wait (possibly infinitely) for them to shut down
    @worker_threads.each { |t| t.join }
  end

  # shutdown
  def stop
    @worker_threads.each do |worker|
      begin
        @logger.info("Stopping thread ... ", :thread => worker.inspect)
        worker.wakeup
      rescue
        @logger.error("Cannot stop thread ... try to kill him", :thread => worker.inspect)
        worker.kill
      end
    end
  end

  # --- END plugin interface ------------------------------------------#

  private

  def run_worker_thread(queue)
    Thread.new do
      @logger.info("Starting new worker thread")
      @sqs_poller.run do |record|
        # record is a valid object with the keys ":bucket", ":key", ":size"
        record[:local_file] = File.join(@tempdir, File.basename(key))
        if @s3_downloader.copy_s3object_to_disk(record)
          completed = catch(:skip_delete) do
            @log_processor.process(record, queue)
          end
          @s3_downloader.cleanup_local_object(record)
          # re-throw if necessary:
          throw :skip_delete unless completed
          @s3_downloader.cleanup_s3object(record)
        end
      end
    end
  end

  def hash_key_is_regex(myhash)
    myhash.default_proc = lambda do |hash, lookup|
      result=nil
      hash.each_pair do |key, value|
        if %r[#{key}] =~ lookup
          result=value
          break
        end
      end
      result
    end
    # return input hash (convenience)
    return myhash
  end

end # class
