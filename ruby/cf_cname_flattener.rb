#!/usr/bin/env ruby

require 'json'
require 'net/https'
require 'resolv'
require 'logger'
require 'fileutils'

class CfCnameFlattener
  CNAME                 = '###' # Your CNAME value, i.e. myapp.herokuapp.com
  CLOUDFLARE_API_KEY    = '###' # Your CloudFlare client API key found at https://www.cloudflare.com/my-account
  CLOUDFLARE_EMAIL      = '###' # Your CloudFlare email address
  CLOUDFLARE_DOMAIN     = '###' # Your CloudFlare domain that you're using this for
  TTL                   = '###' # TTL for records created - 120 recommended
  NAMESERVER            = nil   # Nameserver(s) to use for resolving CNAME. Leave nil for default, or an Array.

  BUGSNAG_API_KEY       = nil

  LOG_PATH              = ENV['LOG_PATH'] || 'cf_cname_flattener.log'
  LOG_ROTATION_PERIOD   = ENV['LOG_ROTATION_PERIOD'] || 'weekly'

  attr_reader :logger

  def initialize
    @logger = Logger.new(LOG_PATH, LOG_ROTATION_PERIOD)
  end

  def flatten!
    add_new_A_records
    delete_old_A_records
  end

  private

  def add_new_A_records
    ip_addresses_to_be_added.each do |ip_address|
      cloudflare_api_client.add_A_record(CLOUDFLARE_DOMAIN, ip_address)
    end
  end

  def delete_old_A_records
    ip_addresses_to_be_deleted.each do |ip_address|
      cloudflare_api_client.delete_A_record(CLOUDFLARE_DOMAIN, ip_address)
    end
  end

  def ip_addresses_to_be_added
    ip_addresses_from_cname - ip_addresses_in_cloudflare
  end

  def ip_addresses_to_be_deleted
    ip_addresses_in_cloudflare - ip_addresses_from_cname
  end

  def ip_addresses_in_cloudflare
    cloudflare_api_client.all_A_records(CLOUDFLARE_DOMAIN)
  end

  def ip_addresses_from_cname
    dns_resolver.ip_addresses(CNAME)
  end

  def cloudflare_api_client
    @cloudflare_api_client ||= CloudFlareAPIClient.new(logger, CLOUDFLARE_API_KEY, CLOUDFLARE_EMAIL, CLOUDFLARE_DOMAIN)
  end

  def dns_resolver
    @dns_resolver ||= DNSResolver.new(NAMESERVER)
  end

  ###########################################################

  class DNSResolver
    attr_reader :resolver

    def initialize(nameserver = nil)
      options = {}
      options[:nameserver] = nameserver if nameserver
      @resolver = Resolv::DNS.new(options)
    end

    def ip_addresses(name)
      resources(name).map {|resource| resource.address.to_s}
    end

    private

    def resources(name, type = Resolv::DNS::Resource::IN::A)
      resolver.getresources(name, type)
    end
  end

  ###########################################################

  class CloudFlareAPIClient
    attr_reader :logger, :api_key, :email, :domain

    def initialize(logger, api_key, email, domain)
      @logger = logger
      @api_key = api_key
      @email = email
      @domain = domain
    end

    def all_A_records(reload = false)
      @all_A_records = nil if reload
      @all_A_records ||=
        begin
          response = request(a: 'rec_load_all')
          records = response['response']['recs']['objs'].map do |record|
            if record['name'] == domain && record['type'] == 'A'
              [record['content'], record['rec_id']]
            end
          end
          Hash[*records.compact]
        end
    end

    def add_A_record(ip_address)
      response = add_record(domain, ip_address)
      proxy_record(response['response']['rec']['obj']['rec_id'], response['response']['rec']['obj']['rec_tag'])
    end

    def delete_A_record(ip_address)
      rec_id = all_A_records[ip_address]
      delete_record(rec_id) if rec_id
    end

    private

    def request(params)
      uri.query = URI.encode_www_form(default_params.merge(params))
      http.start do
        http.request_get(uri.path) do |response|
          return JSON.parse(response.body)
        end
      end
    end

    def http
      @http ||= Net::HTTP.new(uri.host, uri.port).tap {|h| h.use_ssl = true}
    end

    def default_params
      {tkn: api_key, email: email, z: domain}.freeze
    end

    def uri
      @uri ||= URI('https://www.cloudflare.com/api_json.html')
    end

    def add_record(type, ip)
      logger.debug { "Adding #{type} Record: #{domain} => #{ip}" }
      request(
        a: 'rec_new',
        type: type,
        name: domain,
        content: ip,
        ttl: TTL,
        service_mode: '1',
      )
    end

    def proxy_record(rec_id, rtag)
      request(
        a: 'rec_proxy',
        id: rec_id,
        rtag: rtag,
        service_mode: '0',
      )
    end

    def delete_record(rec_id)
      logger.debug { "Deleting A Record: #{rec_id}" }
      request(
        a: 'rec_delete',
        id: rec_id,
      )
    end
  end

end
if __FILE__ == $0
  def with_bugsnag(&block)
    if CfCnameFlattener::BUGSNAG_API_KEY
      begin
        require 'bugsnag'
      rescue LoadError
      end

      if defined?(Bugsnag)
  begin
    begin
      require 'bugsnag'
    rescue LoadError
    end
    if defined?(Bugsnag)
        Bugsnag.configure do |config|
          config.api_key = CfCnameFlattener::BUGSNAG_API_KEY
          config.use_ssl = true
        end
      end

      begin
        yield
      rescue Exception => e
        Bugsnag.notify(e) if defined?(Bugsnag)
      end
    else
      yield
    end
  end

  with_bugsnag do
    CfCnameFlattener.new.flatten!
  end
end
