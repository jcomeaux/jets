require "base64"
require "json"
require "active_support/core_ext/string"

class Jets::Call
  autoload :Guesser, "jets/call/guesser"
  include Jets::AwsServices

  def initialize(provided_function_name, event, options={})
    @options = options
    @guess = @options[:guess].nil? ? true : @options[:guess]

    @provided_function_name = provided_function_name
    @event = event

    @invocation_type = options[:invocation_type] || "RequestResponse"
    @log_type = options[:log_type] || "Tail"
    @qualifier = @qualifier

    Jets.confirm_jets_project!
  end

  def function_name
    if @guess
      ensure_guesses_found! # possibly exits here
      guesser.function_name # guesser adds namespace already
    else
      [Jets.config.project_namespace, @provided_function_name].join('-')
    end
  end

  def run
    @options[:local] ? local_run : remote_run
  end

  # With local run there is no way to bypass the guesser
  def local_run
    puts "Local mode enabled!"
    ensure_guesses_found! # possibly exits here
    klass = guesser.class_name.constantize
    # Example:
    #   PostsController.process(event, context, meth)
    data = klass.process(transformed_event, {}, guesser.method_name)
    # Note: even though data might not always be json, the JSON.dump does a
    # good job of not bombing, so always calling it to simplify code.
    $stdout.puts JSON.dump(data)
  end

  def remote_run
    puts "Calling lambda function #{function_name} on AWS".colorize(:green)
    return if @options[:noop]

    begin
      resp = lambda.invoke(
        # client_context: client_context,
        function_name: function_name,
        invocation_type: @invocation_type, # "Event", # RequestResponse
        log_type: @log_type, # pretty sweet
        payload: transformed_event, # "fileb://file-path/input.json",
        qualifier: @qualifier, # "1",
      )
    rescue Aws::Lambda::Errors::ResourceNotFoundException
      puts "The function #{function_name} was not found.  Maybe check the spelling?".colorize(:red)
      exit
    end

    if @options[:show_log]
      puts "Last 4KB of log in the x-amz-log-result header:".colorize(:green)
      puts Base64.decode64(resp.log_result)
    end

    add_console_link_to_clipboard
    $stdout.puts resp.payload.read # only thing that goes to stdout
  end

  def guesser
    @guesser ||= Guesser.new(@provided_function_name)
  end

  def ensure_guesses_found!
    unless guesser.class_name and guesser.method_name
      puts guesser.error_message
      exit
    end
  end

  def transformed_event
    text = @event

    if text && text.include?("file://")
      path = text.gsub('file://','')
      path = "#{Jets.root}#{path}" unless path[0..0] == '/'
      unless File.exist?(path)
        puts "File #{path} does not exist.  Are you sure the file exists?".colorize(:red)
        exit
      end
      text = IO.read(path)
    end

    puts "Function name: #{function_name.inspect}"
    return text unless function_name.include?("_controller-")
    return text if @options[:lambda_proxy] == false

    event = JSON.load(text)
    lambda_proxy = {"queryStringParameters" => event}
    JSON.dump(lambda_proxy)
  end

  # So use can quickly paste this into their browser if they want to see the function
  # via the Lambda console
  def add_console_link_to_clipboard
    return unless RUBY_PLATFORM =~ /darwin/
    return unless system("type pbcopy > /dev/null")

    # TODO: for add_console_link_to_clipboard get the region from the ~/.aws/config and AWS_PROFILE setting
    region = Aws.config[:region] || 'us-east-1'
    link = "https://console.aws.amazon.com/lambda/home?region=#{region}#/functions/#{function_name}?tab=configuration"
    system("echo #{link} | pbcopy")
    puts "Pro tip: The Lambda Console Link to the #{function_name} function has been added to your clipboard."
  end

  # Client context must be a valid Base64-encoded JSON object
  # Example: http://docs.aws.amazon.com/mobileanalytics/latest/ug/PutEvents.html
  # TODO: figure out how to sign client_context
  def client_context
    context = {
      "client" => {
        "client_id" => "Jets",
        "app_title" => "jets call cli",
        "app_version_name" => Jets::VERSION,
      },
      "custom" => {},
      "env" =>{
        "platform" => RUBY_PLATFORM,
        "platform_version" => RUBY_VERSION,
      }
    }
    Base64.encode64(JSON.dump(context))
  end

  # For this class redirect puts to stderr so user can pipe output to tools like
  # jq. Example:
  #   jets call posts_controller-index '{"test":1}' | jq .
  def puts(text)
    $stderr.puts(text)
  end
end