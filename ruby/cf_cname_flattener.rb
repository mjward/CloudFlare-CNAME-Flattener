#!/usr/bin/ruby

require 'json'
require 'net/http'
require 'socket'
require 'logger'
require 'bugsnag'
require 'fileutils'

class CfCnameFlattener

  attr_reader :logger

  CNAME       = '###' # Your CNAME value, i.e. myapp.herokuapp.com
  API         = '###' # Your CloudFlare client API key found at https://www.cloudflare.com/my-account
  EMAIL       = '###' # Your CloudFlare email address
  DOMAIN      = '###' # Your CloudFlare domain that you're using this for
  TTL         = '###' # TTL for records created - 120 recommended

  def initialize
    @logger = Logger.new('cf_flattener.log')
  end

  def flatten
    cname_ips = get_new_ips
    cf_records = get_current_ips
    do_not_touch = []

    cname_ips.each do |ip|
      unless cf_records.has_key?(ip)
        response = add_record('A', DOMAIN, ip)
        proxy_record(response['response']['rec']['obj']['rec_id'], response['response']['rec']['obj']['rec_tag'])
      else
        do_not_touch << cf_records[ip]
      end
    end
    prune_unused(do_not_touch, cf_records)
    record_activity
  end 

  def get_new_ips
    resolve = Socket.getaddrinfo(CNAME, "http", nil, :STREAM)
    resolve.map { |i| i[2] }
  end

  def api_call(params)
    params.merge!(core_params)
    uri = URI('https://www.cloudflare.com/api_json.html')
    uri.query = URI.encode_www_form(params)
    request = Net::HTTP.get_response(uri)
    JSON.parse(request.body)
  end

  def core_params
    { tkn: API, email: EMAIL, z: DOMAIN }
  end

  def get_current_ips
    records = record_list
    ips = {}
    records['response']['recs']['objs'].each do |record|
      if record['name'] == DOMAIN && record['type'] == 'A'
        ips[record['content']] = record['rec_id']
      end
    end
    ips
  end

  def record_list
    params = { a: 'rec_load_all' }
    api_call(params)
  end

  def add_record(type, name, ip)
    params = {
      a: 'rec_new',
      type: type,
      name: name,
      content: ip,
      ttl: TTL,
      service_mode: '1'
    }
    logger.debug "Adding #{type} Record: #{name} => #{ip}"
    api_call(params)
  end

  def proxy_record(rec_id, rtag)
    params = {
      a: 'rec_proxy',
      id: rec_id,
      rtag: rtag,
      service_mode: '0'
    }
    api_call(params)
  end

  def delete_record(rec_id)
    params = {
      a: 'rec_delete',
      id: rec_id
    }
    logger.debug "Deleting A Record: #{DOMAIN} => #{ip}"
    api_call(params)
  end

  def prune_unused(exclusion, current_records)
    current_records.each do |ip, rec_id|
      unless exclusion.include?(rec_id)
        delete_record(rec_id, ip)
      end
    end
  end

  def record_activity
    FileUtils.touch '/tmp/cname-flattener' 
  end

end

CfCnameFlattener.new().flatten

Bugsnag.configure do |config|
  config.api_key = "ccac972773b4f3ea02030a0d87a4775a"
  config.use_ssl = true
end

at_exit do
  if $!
    Bugsnag.notify($!)
  end
end
