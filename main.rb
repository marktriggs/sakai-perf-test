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

class SimulatedUser

  # Each user will select this many tools
  TOOLS_TO_HIT = 10

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

  UUID_REGEX = /[a-f0-9]+-[a-f0-9]+-[a-f0-9]+-[a-f0-9]+-[a-f0-9]+/
  SITES_REGEX = %r{/portal/site/(#{UUID_REGEX})" title="(.*?)"}
  TOOL_REGEX = %r{(/portal/site/#{UUID_REGEX}/tool/#{UUID_REGEX})" title="(.*?)"}
  WORKSPACE_REGEX = %r{(/portal/site/%7E.*?)" title="Home"}

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
      select_random_tools(response, site_id, site_title, TOOLS_TO_HIT)
    end
  end

  def select_random_tools(last_response, site_id, site_title, tools_to_hit)
    tools = last_response.content.scan(TOOL_REGEX).compact.uniq

    if tools.empty?
      return fail_user("No tools for #{site_id}")
    end

    (tool_url, tool_title) = tools.sample

    http.get(uri(tool_url)) do |response|
      log(":response_ms=#{sprintf('%-6s', response.duration)} :status=#{response.status} :site_id=#{site_id} :site_title=#{sprintf('%-30.30s', site_title)} :tool_title=#{sprintf('%-30.30s', tool_title)}")

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
    @http = HttpClient.new
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
  end
end

Main.run(ARGV)
