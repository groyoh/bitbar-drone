#!/usr/bin/env ruby
# frozen_string_literal: true

#
# <bitbar.title>Bitbar Drone</bitbar.title>
# <bitbar.version>v0.1</bitbar.version>
# <bitbar.author>Yohan Robert</bitbar.author>
# <bitbar.author.github>groyoh</bitbar.author.github>
# <bitbar.desc>List builds on your Drone server.</bitbar.desc>
# <bitbar.dependencies>ruby</bitbar.dependencies>
# <bitbar.abouturl>https://github.com/groyoh/bitbar-drone</bitbar.abouturl>

require 'net/http'
require 'json'

# Your drone server URL.
BASE_URL = 'https://your.drone.server/'

# Your drone personal token.
TOKEN = 'your.token'

# The list of Github handles whose builds you'd like to display.
# Leave empty to retrieve builds from every users.
AUTHORS = %w[groyoh].map(&:downcase).freeze

# The list of repositories whose builds you'd like to display.
REPOSITORIES = ['your/repo'].freeze

# The base branch of your repository.
BASE_BRANCH = 'master'

# A build is displayed as recent if it is created less than
# `DISPLAY_BUILD_AS_RECENT_INTERVAL` seconds ago. Default is 1h.
DISPLAY_BUILD_AS_RECENT_INTERVAL = 3_600

# A build is displayed if it is created less than `DISPLAY_BUILD_INTERVAL`
# seconds ago. Default is 5h.
DISPLAY_BUILD_INTERVAL = 5 * 3_600

# Colors module contains color constants.
module Colors
  NONE = 'none'
  GREEN = 'green'
  RED = 'red'
  ORANGE = 'orange'
end

# Build represents a Drone build.
class Build
  attr_reader :repository,
              :author_login,
              :event,
              :source,
              :target,
              :status,
              :number,
              :title,
              :message,
              :link,
              :started_at,
              :created_at

  def initialize(repository, attributes)
    @repository = repository
    @author_login = attributes.fetch('author_login', '').downcase
    @event = attributes.fetch('event')
    @target = attributes.fetch('target')
    @source = attributes.fetch('source')
    @status = attributes.fetch('status')
    @number = attributes.fetch('number')
    @title = attributes.fetch('title', '')
    @message = attributes.fetch('message')
    @link = attributes.fetch('link')
    @started_at = Time.at(attributes.fetch('started', 0))
    @created_at = Time.at(attributes.fetch('created', 0))
  end
end

# Repository represents a Github repository.
class Repository
  attr_reader :slug

  def initialize(slug)
    @slug = slug
  end
end

# DroneClient is a client to fetch Drone repositories and builds.
class DroneClient
  AUTHORIZATION_HEADER = 'Authorization'
  REPOSITORIES_PATH = '/api/user/repos'
  BUILDS_PATH = '/api/repos/{slug}/builds'

  def initialize(base_url, token)
    base_uri = URI.parse(base_url)
    @base_url = base_uri
    @token = token
  rescue URI::InvalidURIError => _e
    raise ArgumentError, "Invalid BASE_URL: #{base_url}"
  end

  def builds(repo)
    page = 1
    builds = []
    loop do
      new_builds = get(BUILDS_PATH.sub('{slug}', repo.slug), per_page: 100, page: page)
      new_builds.map! { |build| Build.new(repo, build) }
      builds.concat(new_builds)
      return builds if new_builds.length < 100 ||
                       (new_builds.last.created_at < Time.now - DISPLAY_BUILD_INTERVAL)

      page += 1
    end
  end

  def repositories
    repos = get(REPOSITORIES_PATH)
    repos.map { |repo| Repository.new(repo['slug']) }
  end

  private

  attr_reader :base_url, :token

  def get(path, params = {})
    uri = base_url.dup
    uri.path = path
    uri.query = URI.encode_www_form(params)

    req = Net::HTTP::Get.new(uri)
    req[AUTHORIZATION_HEADER] = token

    res =
      begin
        Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
          http.request(req)
        end
      rescue StandardError
        raise StandardError, 'Failed to connect to Drone'
      end

    raise StandardError, 'Verify your Drone token' if res.code == '401'

    if res.code != '200'
      raise StandardError, "Request failed with status #{res.code}"
    end

    JSON.parse(res.body)
  end
end

# BitbarOuput provide function to display output expected by Bitbar
class BitbarOutput
  def initialize(title, color: Colors::NONE)
    @title = line(title, color: color)
    @output = ''
  end

  def error(err)
    self.output = ''
    title(err, color: Colors::RED)
    print
  end

  def title(title, color: Colors::NONE)
    @title = line(title, color: color, length: nil)
  end

  def menu(title, color: Colors::NONE, href: nil, bash: nil, terminal: nil, params: nil, alternate: false, length: 50)
    self.output += line(
      title,
      color: color,
      href: href,
      bash: bash,
      terminal: terminal,
      params: params,
      alternate: alternate,
      length: length
    )
  end

  def submenu(title, color: Colors::NONE, href: nil, bash: nil, terminal: nil, params: nil, alternate: false, length: 50)
    self.output += '--'
    menu(
      title,
      color: color,
      href: href,
      bash: bash,
      terminal: terminal,
      params: params,
      alternate: alternate,
      length: length
    )
  end

  def separator
    self.output = "---\n"
  end

  def print
    puts "#{@title}---\n#{output}"
  end

  protected

  attr_accessor :output

  private

  def line(title, color: Colors::NONE, href: nil, bash: nil, terminal: nil, params: nil, alternate: false, length: nil)
    line = ''
    line += title

    line += ' |'
    line += " color='#{color}'" if color != Colors::NONE

    line += " href='#{href}'" if href

    if bash
      line += " bash='#{bash}'"
      line += " terminal=#{terminal}" if terminal == true || terminal == false
      params&.each_with_index { |value, index| line += " param#{index + 1}='#{value}'" }
    end

    line += " length=#{length}" if length
    line += " alternate=#{alternate}" if alternate

    line += " \n"
  end
end

def print_build(output, build, with_author: false, with_repo: false)
  title = ''
  color = Colors::GREEN
  href = URI.parse(BASE_URL)
  href.path = File.join('', build.repository.slug, build.number.to_s)
  href = href.to_s

  if build.event == 'pull_request'
    title = build.title.to_s
  elsif build.target == BASE_BRANCH
    title = build.message.to_s
  else
    return
  end

  title = title.split("\n").first
  title = title[0..50] + '...' if title.length > 50

  if %w[pending running].include?(build.status.to_s.downcase)
    color = Colors::ORANGE
  elsif build.status == 'failure'
    color = Colors::RED
  end

  output.menu(title, color: color, href: href)

  output.submenu(build.source)
  if build.event == 'pull_request'
    output.submenu('Go to PR', href: build.link.sub('.diff', ''))
    output.submenu('Copy branch', bash: '/bin/bash', params: ['-c', "'/usr/bin/printf #{build.source} | /usr/bin/pbcopy'"], terminal: false)
  end

  alternate = "#{build.event} from #{build.author_login} on #{build.repository.slug}"
  output.menu(alternate, color: 'white', alternate: true, length: nil)
end

def print_builds(output, builds, with_author: false, with_repo: false)
  builds.each { |build| print_build(output, build, with_author: with_author, with_repo: with_repo) }
end

def author_builds(builds_grouped_by_author, author)
  builds_grouped_by_author[author] || []
end

def sort_builds(builds)
  builds.sort { |build| build.created_at.to_i }
end

def recent_builds(builds)
  sort_builds(
    builds
    .select { |build| build.created_at >= Time.now - DISPLAY_BUILD_AS_RECENT_INTERVAL }
  )
end

def older_builds(builds)
  builds = builds.select do |build|
    build.created_at >= (Time.now - DISPLAY_BUILD_INTERVAL) &&
      build.created_at < (Time.now - DISPLAY_BUILD_AS_RECENT_INTERVAL)
  end
  builds.sort_by! { |b| -b.created_at.to_i }
end

def set_title(output, builds_grouped_by_repo)
  failures = false
  pending = false
  builds_grouped_by_repo.each do |_, builds|
    builds = recent_builds(builds)
    failures = true if builds.any? && builds.first.status == 'failure'
    if builds.any? { |build| %w[pending running].include?(build.status.to_s.downcase) }
      pending = true
    end
  end

  if failures
    output.title('Drone IO', color: Colors::RED)
  elsif pending
    output.title('Drone IO', color: Colors::ORANGE)
  else
    output.title('Drone IO', color: Colors::GREEN)
  end
end

client = DroneClient.new(BASE_URL, TOKEN)
output = BitbarOutput.new('Drone IO')

if DISPLAY_BUILD_INTERVAL < DISPLAY_BUILD_AS_RECENT_INTERVAL
  output.error('DISPLAY_BUILD_INTERVAL must be greater than DISPLAY_BUILD_AS_RECENT_INTERVAL')
  exit(1)
end

begin
  builds_grouped_by_repo = {}
  builds = []
  client
    .repositories
    .select { |repo| REPOSITORIES.include?(repo.slug) }
    .each do |repo|
      repo_builds = client.builds(repo)
      repo_builds.select! { |b| AUTHORS.empty? || AUTHORS.include?(b.author_login.downcase) }
      builds_grouped_by_repo[repo.slug] = repo_builds
      builds.concat(repo_builds)
    end

  builds_grouped_by_repo.each do |slug, builds|
    recent_builds = recent_builds(builds)

    next if recent_builds.empty?

    recent_builds_grouped_by_author = recent_builds.group_by(&:author_login)

    AUTHORS.each do |author|
      recent_author_builds = recent_builds_grouped_by_author[author]
      next unless recent_author_builds&.any?

      output.menu("Recent builds from #{author} on #{slug}")
      print_builds(output, recent_author_builds)
    end
  end

  set_title(output, builds_grouped_by_repo)

  output.menu('Older builds')
  print_builds(output, older_builds(builds), with_author: true, with_repo: true)

  output.print
rescue StandardError => e
  output.error(e.message)
  exit(1)
end
