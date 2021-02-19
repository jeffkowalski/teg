sr#!/usr/bin/env ruby
# frozen_string_literal: true

require 'thor'
require 'fileutils'
require 'logger'
require 'rest-client'
require 'json'
require 'influxdb'
require 'date'
require 'yaml'

LOGFILE = File.join(Dir.home, '.log', 'teg.log')
CREDENTIALS_PATH = File.join(Dir.home, '.credentials', 'teg.yaml')

module Kernel
  def with_rescue(exceptions, logger, retries: 5)
    try = 0
    begin
      yield try
    rescue *exceptions => e
      try += 1
      raise if try > retries

      logger.info "caught error #{e.class}, retrying (#{try}/#{retries})..."
      retry
    end
  end
end

class Teg < Thor
  no_commands do
    def redirect_output
      unless LOGFILE == 'STDOUT'
        logfile = File.expand_path(LOGFILE)
        FileUtils.mkdir_p(File.dirname(logfile), mode: 0o755)
        FileUtils.touch logfile
        File.chmod 0o644, logfile
        $stdout.reopen logfile, 'a'
      end
      $stderr.reopen $stdout
      $stdout.sync = $stderr.sync = true
    end

    def setup_logger
      redirect_output if options[:log]

      @logger = Logger.new $stdout
      @logger.level = options[:verbose] ? Logger::DEBUG : Logger::INFO
      @logger.info 'starting'
    end
  end

  class_option :log,     type: :boolean, default: true, desc: "log output to #{LOGFILE}"
  class_option :verbose, type: :boolean, aliases: '-v', desc: 'increase verbosity'

  desc 'record-status', 'record the current production data to database'
  method_option :dry_run, type: :boolean, aliases: '-n', desc: "don't log to database"
  def record_status
    setup_logger

    begin
      credentials = YAML.load_file CREDENTIALS_PATH
      influxdb = options[:dry_run] ? nil : (InfluxDB::Client.new 'teg')

      data = []

      jar = with_rescue([RestClient::BadGateway, RestClient::GatewayTimeout, RestClient::Exceptions::OpenTimeout], @logger) do |_try|
        headers = {
          content_type: :json
        }
        payload = {
          username: 'customer',
          email: credentials[:email],
          password: credentials[:password],
          force_sm_off: false
        }
        response = RestClient::Request.execute(method: :post, url: 'https://192.168.7.205/api/login/Basic', headers: headers, payload: payload.to_json, verify_ssl: false)
        response.cookie_jar
      end

      meters = with_rescue([RestClient::BadGateway, RestClient::GatewayTimeout, RestClient::Exceptions::OpenTimeout], @logger) do |_try|
        response = RestClient::Request.execute(method: :get, url: 'https://192.168.7.205/api/meters/aggregates', cookies: jar, verify_ssl: false)
        JSON.parse response
      end
      @logger.debug meters
      %w[site battery load solar].each do |device|
        timestamp = meters[device]['last_communication_time'] # "2021-02-01T14:43:06.590679464-08:00"
        timestamp = (DateTime.parse timestamp).to_time.to_i
        [
          'instant_power',           # 20
          'instant_reactive_power',  # 88
          'instant_apparent_power',  # 90.24411338142782
          'frequency',               # 0
          'energy_exported',         # 29.19518524360683
          'energy_imported',         # 865.0427431281169
          'instant_average_voltage', # 215.986735703839
          'instant_total_current',   # 7.971
          'i_a_current',             # 0
          'i_b_current',             # 0
          'i_c_current',             # 0
          'timeout'                 # 1500000000
        ].each do |measure|
          data.push({ series: measure, values: { value: meters[device][measure].to_f }, tags: { device: device }, timestamp: timestamp })
        end
      end

      soe = with_rescue([RestClient::BadGateway, RestClient::GatewayTimeout, RestClient::Exceptions::OpenTimeout], @logger) do |_try|
        response = RestClient::Request.execute(method: :get, url: 'https://192.168.7.205/api/system_status/soe', cookies: jar, verify_ssl: false)
        JSON.parse response
      end
      @logger.debug soe
      timestamp = Time.now.to_i
      data.push({ series: 'soe', values: { value: soe['percentage'].to_f }, timestamp: timestamp })

      pp data if @logger.level == Logger::DEBUG
      influxdb.write_points data unless options[:dry_run]
    rescue StandardError => e
      @logger.error e
    end
  end
end

Teg.start
