#!/usr/bin/env jruby

# * User logs in
# * Selects a random site
# * Selects a random tool
# * Returns to their workspace
# * Logs out

require 'uri'
require 'securerandom'

require_relative 'lib/jetty-util-9.4.0.M1.jar'
require_relative 'lib/jetty-http-9.4.0.M1.jar'
require_relative 'lib/jetty-io-9.4.0.M1.jar'
require_relative 'lib/jetty-client-9.4.0.M1.jar'

# Give our testers unique names
NAMES = %w(Aaliyah Aaron Abigail Adam Addison Adrian Aiden Alexa Alexander
           Alexis Alice Allison Alyssa Amelia Andrew Angel Anna Annabelle
           Anthony Aria Ariana Arianna Asher Ashley Aubree Aubrey Audrey Aurora
           Austin Autumn Ava Avery Ayden Bella Benjamin Bentley Blake Brandon
           Brayden Brianna Brooklyn Caleb Cameron Camila Caroline Carson Carter
           Charles Charlotte Chase Chloe Christian Christopher Claire Clara
           Colton Connor Cooper Cora Daniel David Dominic Dylan Easton Eleanor
           Eli Elias Elijah Elizabeth Ella Ellie Emily Emma Ethan Eva Evan
           Evelyn Ezra Faith Gabriel Gabriella Gavin Genesis Gianna Grace
           Grayson Hailey Hannah Harper Hazel Henry Hudson Hunter Ian Isaac
           Isabella Isabelle Isaiah Jace Jack Jackson Jacob James Jason Jaxon
           Jaxson Jayden Jeremiah John Jonathan Jordan Jose Joseph Joshua Josiah
           Julia Julian Katherine Kayden Kaylee Kennedy Kevin Khloe Kylie Landon
           Layla Leah Leo Levi Liam Lillian Lily Lincoln Logan Lucas Lucy Luke
           Lydia Mackenzie Madeline Madelyn Madison Mason Mateo Matthew Maya
           Melanie Mia Michael Mila Naomi Natalie Nathan Nathaniel Nevaeh
           Nicholas Noah Nolan Nora Oliver Olivia Owen Paisley Parker Penelope
           Peyton Piper Quinn Reagan Riley Robert Ruby Ryan Ryder Sadie Samantha
           Samuel Sarah Savannah Sawyer Scarlett Sebastian Serenity Skylar Sofia
           Sophia Stella Taylor Theodore Thomas Tyler Victoria Violet Vivian
           William Wyatt Xavier Zachary Zoe Zoey)

java_import org.eclipse.jetty.client.HttpClient

class StatsCollector

  @stats = java.util.Collections.synchronizedList(java.util.ArrayList.new)

  def self.tool_stat(tool_name, duration, was_error)
    @stats << Stat.new(tool_name, duration, was_error)
  end

  def self.dump_stats
    $stderr.puts("=" * 71)
    $stderr.puts("\nStats by tool:\n\n")
    stats_by_tool = @stats.group_by {|stat| stat.tool_name}

    stats_by_tool.keys.sort.each do |tool_name|
      $stderr.puts(tool_name)
      $stderr.puts('-' * tool_name.length)
      summarize_stats(stats_by_tool[tool_name])
      $stderr.puts("")
    end

    $stderr.puts("\nStats for entire run:\n\n")
    summarize_stats(@stats)

    $stderr.puts("")
    $stderr.puts("=" * 71)
  end

  def self.summarize_stats(stats)
    return if stats.empty?

    tool_count = stats.length
    min_time = stats.min_by {|stat| stat.duration}.duration
    max_time = stats.max_by {|stat| stat.duration}.duration
    error_count = stats.count {|stat| stat.was_error}

    $stderr.puts("  Request count: #{tool_count}")
    $stderr.puts("  Best time: #{min_time}")
    $stderr.puts("  Worst time: #{max_time}")
    $stderr.puts("  Error count: #{error_count}")

    step = 50
    max_bucket = (max_time / step.to_f).ceil * step
    buckets = [0, 50, 100, 150, 200, 300, 400, 500, 1000] + (2000..max_bucket).step(1000).to_a

    buckets.zip(buckets.drop(1)).each do |lower, upper|
      break unless upper

      reading_count = stats.count {|stat| stat.duration >= lower && stat.duration < upper}

      next unless reading_count > 0

      percent = sprintf('%.2f', (reading_count / tool_count.to_f) * 100)

      $stderr.puts(sprintf('    %4dms - %-4dms: %s%%',
                           lower,
                           upper - 1,
                           percent))

      break if !upper || upper > max_time
    end


  end

  Stat = Struct.new(:tool_name, :duration, :was_error)
end

class SimulatedUser

  # Each user will select this many tools
  TOOLS_TO_HIT = 50

  attr_reader :http, :base_url

  def initialize(http, base_url)
    @http = http
    @base_url = base_url
    @my_id = 3.times.map {|_| NAMES.sample}.join(' ')
  end

  def login(test_user)
    log("Logging in as user #{test_user}")

    http.post(uri('/portal/relogin'),
              'eid' => test_user.username,
              'pw' => test_user.password,
              'submit' => 'Login') do |response|
      select_random_site(response)
    end
  end

  private

  UUID_REGEX = /[a-f0-9]+-[a-f0-9]+-[a-f0-9]+-[a-f0-9]+-[a-f0-9]+|[a-f0-9]{32}/
  SITES_REGEX = %r{/portal/site/(#{UUID_REGEX})" title="(.*?)"}

  # Sakai 10.7 uses page; 11 uses tool
  TOOL_REGEX = %r{(/portal/site/#{UUID_REGEX}/(?:tool|page)/#{UUID_REGEX})" title="(.*?)"}
  IFRAME_TOOL_REGEX = %r{src=.*(/portal/tool/#{UUID_REGEX}.*?)"}
  WORKSPACE_REGEX = %r{(/portal/site/%7E.*?)" title="(Home|My Workspace)"}


  def log(s)
    $stderr.write("#{(Time.now.to_f * 1000).to_i} #{sprintf('%-40s', @my_id)} #{s}\n")
  end

  def uri(s)
    URI.join(@base_url, s).to_s
  end

  def fail_user(msg)
    log("FAILED: #{msg}")
  end

  def select_random_site(last_response)
    site_id, site_title = last_response.content.scan(SITES_REGEX).compact.uniq.sample

    return fail_user("No site id found") unless site_id

    http.get(uri("/portal/site/#{site_id}")) do |response|
      select_random_tools(response, site_id, site_title, TOOLS_TO_HIT - 1)
    end
  end

  def select_random_tools(last_response, site_id, site_title, tools_to_hit)
    tools = last_response.content.scan(TOOL_REGEX).compact.uniq

    # Skip these for now because they're outliers
    tools = tools.reject {|t| t[1] =~ /Gradebook|NYU Libraries/}

    if tools.empty?
      $stderr.puts(last_response.content)
      return fail_user("No tools for #{site_id}")
    end

    (tool_url, tool_title) = tools.sample

    outer_response = nil

    if tool_url =~ /\/page\//
      # If we're in Sakai 10 land, we've actually just got the outer page.  Need
      # to fetch the inner iframe for the tool
      http.get(uri(tool_url)) do |response|
        outer_response = response
        tool_url = response.content.scan(IFRAME_TOOL_REGEX).flatten.compact.first
      end
    end

    http.get(uri(tool_url)) do |response|
      aggr_duration = response.duration + (outer_response ? outer_response.duration : 0)
      log(":response_ms=#{sprintf('%-6s', aggr_duration)} :status=#{response.status} :site_id=#{site_id} :site_title=#{sprintf('%-30.30s', site_title)} :tool_title=#{sprintf('%-30.30s', tool_title)}")

      StatsCollector.tool_stat(tool_title, aggr_duration, response.error?)

      if tools_to_hit == 0
        return_to_workspace(response)
      else
        select_random_tools(response, site_id, site_title, tools_to_hit - 1)
      end
    end
  end

  def return_to_workspace(last_response)
    workspace = last_response.content.scan(WORKSPACE_REGEX).flatten.compact.first

    return fail_user("Couldn't get a workspace") unless workspace

    http.get(uri(workspace)) do |response|
      logout(response)
    end
  end

  def logout(last_response)
    http.post(uri('/portal/logout')) do |_|
      http.dump_status
    end
  end

end


class AsyncHttpClient

  attr_reader :http

  def initialize
    @http = HttpClient.new(org.eclipse.jetty.util.ssl.SslContextFactory.new)
    @http.start

    # Sci-fi!
    @phaser = java.util.concurrent.Phaser.new
    @phaser.register
  end

  def dump_status
    $stderr.write("#{(Time.now.to_f * 1000).to_i} #{sprintf('%-40s', 'HTTP')} Requests currently pending: #{@phaser.get_registered_parties - @phaser.get_arrived_parties}\n")
  end

  def get(url, &block)
    request(url, org.eclipse.jetty.http.HttpMethod::GET, {}, &block)
  end

  def post(url, params = {}, &block)
    request(url, org.eclipse.jetty.http.HttpMethod::POST, params, &block)
  end

  def request(url, method, params = {}, &block)
    @phaser.register
    response = Response.new

    request = http.new_request(url).method(method)

    params.each do |key, value|
      request.param(key, value)
    end

    request.onResponseContent {|_, buffer| response.add_content(buffer)}.send do |result|
      response.status = result.response.get_status
      begin
        block.call(response)
      ensure
        @phaser.arrive
      end
    end
  end

  def wait
    # Wait for all outstanding requests to finish
    @phaser.arrive_and_await_advance
    @http.stop
  end

  class Response
    def initialize
      @content = []
      @status = :unknown
      @start_time = java.lang.System.currentTimeMillis
    end

    def add_content(buffer)
      bytes = Java::byte[buffer.remaining].new
      buffer.get(bytes)

      @content << java.lang.String.new(bytes, "UTF-8")
    end

    def content
      result = ""

      @content.each do |java_str|
        result << java_str.to_s
      end

      result
    end

    def status
      @status
    end

    def status=(code)
      @status = code
      @end_time = java.lang.System.currentTimeMillis
    end

    def duration
      @end_time - @start_time
    end

    def error?
      status.to_s =~ /^[54]/
    end
  end
end


class Main

  attr_reader :base_url, :user_count

  def self.run(args)
    base_url = args.fetch(0) { educate! }
    user_count = Integer(args.fetch(1) { educate! })

    new(base_url, :simulate_users => user_count).call

  end

  def self.educate!
    puts "Usage: main.rb <sakai_base_url> <user count>"
    exit
  end

  def initialize(base_url, opts)
    @base_url = base_url
    @user_count = opts.fetch(:simulate_users)
  end

  TestUser = Struct.new(:username, :password)

  def read_users
    result = []
    users_file = File.join(File.dirname(File.absolute_path(__FILE__)),
                           'users.txt')

    File.read(users_file).split("\n").each do |line|
      next if line.start_with?('#')

      username, password = line.split(' ', 2)
      result << TestUser.new(username, password)
    end

    result
  end

  def call
    available_test_users = read_users
    test_user_idx = 0

    clients = []

    @user_count.times do |user|
      http = AsyncHttpClient.new
      clients << http

      test_user = available_test_users.fetch(test_user_idx % available_test_users.length)
      test_user_idx += 1

      user = SimulatedUser.new(http, base_url)
      user.login(test_user)
    end

    clients.each(&:wait)

    StatsCollector.dump_stats
  end
end

Main.run(ARGV)
