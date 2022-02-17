#!/usr/bin/env ruby
# frozen_string_literal: true

require 'rubygems'
require 'bundler/setup'
Bundler.require(:default)

class Teg < RecorderBotBase
  no_commands do
    def main
      credentials = load_credentials
      influxdb = options[:dry_run] ? nil : (InfluxDB::Client.new 'teg')

      with_rescue([RestClient::Unauthorized], @logger) do |_try2|
        data = []
        soft_faults = [RestClient::BadGateway, RestClient::GatewayTimeout, RestClient::Exceptions::OpenTimeout]
        jar = with_rescue(soft_faults, @logger) do |_try|
          headers = {
            content_type: :json
          }
          payload = {
            username: 'customer',
            email: credentials[:email],
            password: credentials[:password],
            force_sm_off: false
          }
          response = RestClient::Request.execute(method: :post, url: 'https://teg/api/login/Basic', headers: headers, payload: payload.to_json, verify_ssl: false)
          response.cookie_jar
        end

        meters = with_rescue(soft_faults, @logger) do |_try|
          response = RestClient::Request.execute(method: :get, url: 'https://teg/api/meters/aggregates', cookies: jar, verify_ssl: false)
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

        operation = with_rescue(soft_faults, @logger) do |_try|
          response = RestClient::Request.execute(method: :get, url: 'https://teg/api/operation', cookies: jar, verify_ssl: false)
          JSON.parse response
        end
        @logger.debug operation
        timestamp = Time.now.to_i
        data.push({ series: 'real_mode', values: { value: operation['real_mode'] }, timestamp: timestamp })

        soe = with_rescue(soft_faults, @logger) do |_try|
          response = RestClient::Request.execute(method: :get, url: 'https://teg/api/system_status/soe', cookies: jar, verify_ssl: false)
          JSON.parse response
        end
        @logger.debug soe
        timestamp = Time.now.to_i
        data.push({ series: 'soe', values: { value: soe['percentage'].to_f }, timestamp: timestamp })
        pp data if @logger.level == Logger::DEBUG
        influxdb.write_points data unless options[:dry_run]
      end
    end
  end
end

Teg.start
