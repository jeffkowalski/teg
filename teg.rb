#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
Bundler.require(:default)

class Teg < RecorderBotBase
  desc 'refresh-access-token', 'refresh access token'
  def refresh_access_token
    @logger.info 'refreshing access token'
    credentials = load_credentials('tesla')

    uri = URI('https://fleet-auth.prd.vn.cloud.tesla.com/oauth2/v3/token')
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/x-www-form-urlencoded'
    request.set_form_data(
      'grant_type' => 'refresh_token',
      'client_id' => credentials[:client_id],
      'refresh_token' => credentials[:refresh_token]
    )

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(request)
    end

    @logger.debug response.read_body
    json = JSON.parse(response.body)
    credentials[:access_token] = json['access_token']
    credentials[:refresh_token] = json['refresh_token']
    store_credentials(credentials, 'tesla')
  end

  no_commands do
    def main
      # Load credentials from tesla.yaml (shared with tesla.rb)
      credentials = load_credentials('tesla')
      influxdb = options[:dry_run] ? nil : (InfluxDB::Client.new 'teg')

      soft_faults = [Net::OpenTimeout, Errno::EHOSTUNREACH]

      with_rescue([StandardError], @logger, retries: 2) do |_try|
        data = []

        # Get list of energy sites
        uri = URI('https://fleet-api.prd.na.vn.cloud.tesla.com/api/1/products')
        request = Net::HTTP::Get.new(uri)
        request['Content-Type'] = 'application/json'
        request['Authorization'] = "Bearer #{credentials[:access_token]}"

        response = with_rescue(soft_faults, @logger) do |_try|
          Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
            http.request(request)
          end
        end

        @logger.debug response.read_body
        json = JSON.parse(response.body)

        if json['error']
          @logger.warn "Error accessing Fleet API: #{json['error']}, refreshing token"
          refresh_access_token
          return
        end

        # Find energy sites (not vehicles)
        energy_sites = json['response'].select { |product| product['resource_type'] == 'battery' }

        if energy_sites.empty?
          @logger.error 'No energy sites found'
          return
        end

        # Use the first energy site (or you could iterate through all)
        site_id = energy_sites.first['energy_site_id']
        @logger.info "Querying energy site #{site_id}"

        # Get live status (equivalent to /api/meters/aggregates)
        uri = URI("https://fleet-api.prd.na.vn.cloud.tesla.com/api/1/energy_sites/#{site_id}/live_status")
        request = Net::HTTP::Get.new(uri)
        request['Content-Type'] = 'application/json'
        request['Authorization'] = "Bearer #{credentials[:access_token]}"

        response = with_rescue(soft_faults, @logger) do |_try|
          Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
            http.request(request)
          end
        end

        @logger.debug "Live status response: #{response.body}"
        live_status_json = JSON.parse(response.body)
        @logger.debug "Parsed JSON: #{live_status_json.inspect}"

        live_status = live_status_json['response']

        if live_status.nil?
          @logger.error "Failed to get live status. Full response: #{live_status_json.inspect}"
          return
        end

        # Parse timestamp from the response
        timestamp = DateTime.parse(live_status['timestamp']).to_time.to_i

        # Map Fleet API data to the same structure as before
        # Fleet API provides: solar_power, battery_power, load_power, grid_power
        meters_data = {
          'site' => {
            'instant_power' => live_status['grid_power'] || 0,
            'last_communication_time' => live_status['timestamp']
          },
          'battery' => {
            'instant_power' => live_status['battery_power'] || 0,
            'last_communication_time' => live_status['timestamp']
          },
          'load' => {
            'instant_power' => live_status['load_power'] || 0,
            'last_communication_time' => live_status['timestamp']
          },
          'solar' => {
            'instant_power' => live_status['solar_power'] || 0,
            'last_communication_time' => live_status['timestamp']
          }
        }

        # Record power data for each device
        %w[site battery load solar].each do |device|
          data.push({
                      series: 'instant_power',
                      values: { value: meters_data[device]['instant_power'].to_f },
                      tags: { device: device },
                      timestamp: timestamp
                    })
        end

        # Get site info for operation mode and battery percentage
        uri = URI("https://fleet-api.prd.na.vn.cloud.tesla.com/api/1/energy_sites/#{site_id}/site_info")
        request = Net::HTTP::Get.new(uri)
        request['Content-Type'] = 'application/json'
        request['Authorization'] = "Bearer #{credentials[:access_token]}"

        response = with_rescue(soft_faults, @logger) do |_try|
          Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
            http.request(request)
          end
        end

        @logger.debug "Site info response: #{response.body}"
        site_info = JSON.parse(response.body)['response']

        if site_info
          # Record operation mode (equivalent to /api/operation)
          data.push({
                      series: 'real_mode',
                      values: { value: site_info['default_real_mode'] || 'unknown' },
                      timestamp: timestamp
                    })

          # Record backup reserve percentage
          if site_info['backup_reserve_percent']
            data.push({
                        series: 'backup_reserve',
                        values: { value: site_info['backup_reserve_percent'].to_f },
                        timestamp: timestamp
                      })
          end
        end

        # Record battery percentage (equivalent to /api/system_status/soe)
        percentage_charged = live_status['percentage_charged']
        if percentage_charged
          data.push({
                      series: 'soe',
                      values: { value: percentage_charged.to_f },
                      timestamp: timestamp
                    })
        end

        # Additional useful data from Fleet API
        if live_status['grid_status']
          data.push({
                      series: 'grid_status',
                      values: { value: live_status['grid_status'] },
                      timestamp: timestamp
                    })
        end

        if live_status['island_status']
          data.push({
                      series: 'island_status',
                      values: { value: live_status['island_status'] },
                      timestamp: timestamp
                    })
        end

        pp data if @logger.level == Logger::DEBUG
        influxdb.write_points data unless options[:dry_run]
      end
    rescue StandardError => e
      @logger.error "Exception: #{e.inspect}"
      @logger.error e.backtrace.join("\n")
    end
  end
end

Teg.start
