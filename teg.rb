#!/usr/bin/env ruby
# frozen_string_literal: true

require 'thor'
require 'fileutils'
require 'logger'
require 'rest-client'
require 'json'
require 'influxdb'
require 'date'

LOGFILE = File.join(Dir.home, '.log', 'teg.log')

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
      influxdb = options[:dry_run] ? nil : (InfluxDB::Client.new 'teg')

      data = []

      meters = with_rescue([RestClient::BadGateway, RestClient::GatewayTimeout, RestClient::Exceptions::OpenTimeout], @logger) do |_try|
        response = RestClient::Request.execute(method: :get, url: 'https://192.168.7.205/api/meters/aggregates', verify_ssl: false)
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
        response = RestClient::Request.execute(method: :get, url: 'https://192.168.7.205/api/system_status/soe', verify_ssl: false)
        JSON.parse response
      end
      @logger.debug soe
      data = []
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


__END__

# rubocop:disable Layout/HashAlignment
MEASURES = {
  'CAL0'                => { type: 'to_s', kind: nil },       # ["50", "100"]   The calibration-reference CT sensor size (50A for production, 100A for consumption)
  'CURTIME'             => { type: nil,    kind: nil },       # ["2020,11,30,04,25,49"
  'DATATIME'            => { type: nil,    kind: nil },       # ["2020,11,30,04,25,00"
  'DESCR'               => { type: 'to_s', kind: :property }, # ["Power Meter PVS5M540952p", "Power Meter PVS5M540952c", "Inverter 450051826006667", "Inverter 450051826015034"
  'DETAIL'              => { type: 'to_s', kind: nil },       # ["detail"]
  'DEVICE_TYPE'         => { type: 'to_s', kind: :property }, # ["PVS", "Power Meter", "Inverter"]
  'HWVER'               => { type: 'to_s', kind: nil },       # ["3.3"]
  'ISDETAIL'            => { type: 'to_s', kind: nil },       # [true]
  'MODEL'               => { type: 'to_s', kind: :property }, # ["PV Supervisor PVS5", "PVS5M0400p", "PVS5M0400c", "AC_Module_Type_D"]
  'MOD_SN'              => { type: 'to_s', kind: nil },       # [""]
  'NMPLT_SKU'           => { type: 'to_s', kind: nil },       # [""]
  'OPERATION'           => { type: 'to_s', kind: nil },       # ["noop"]
  'PORT'                => { type: 'to_s', kind: nil },       # [""]
  'SERIAL'              => { type: 'to_s', kind: :property }, # ["ZT163185000441C1876", "PVS5M540952p", "PVS5M540952c", "450051826006667", "450051826015034"
  'STATE'               => { type: 'to_s', kind: :property }, # ["working", "error"]
  'STATEDESCR'          => { type: 'to_s', kind: nil },       # ["Working", "Error"]
  'SWVER'               => { type: 'to_s', kind: nil },       # ["2020.1, Build 3008", "4", "1057177359", "1078804428"]
  'TYPE'                => { type: 'to_s', kind: :property }, # ["PVS5-METER-P", "PVS5-METER-C", "SOLARBRIDGE"]
  'ct_scl_fctr'         => { type: 'to_i', kind: :metric },   # ["50", "100"]   The CT sensor size (50A for production, 100A/200A for consumption)
  'dl_comm_err'         => { type: 'to_i', kind: :metric },   # ["500"]         Number of comms errors
  'dl_cpu_load'         => { type: 'to_f', kind: :metric },   # ["0.09"]        1-minute load average
  'dl_err_count'        => { type: 'to_i', kind: :metric },   # ["0"]           Number of errors detected since last report
  'dl_flash_avail'      => { type: 'to_i', kind: :metric },   # ["12484"]       Amount of free space, in KiB (assumed 1GiB of storage)
  'dl_mem_used'         => { type: 'to_i', kind: :metric },   # ["31660"]       Amount of memory used, in KiB (assumed 1GiB of RAM)
  'dl_scan_time'        => { type: 'to_i', kind: :metric },   # ["1"]
  'dl_skipped_scans'    => { type: 'to_i', kind: :metric },   # ["0"]
  'dl_untransmitted'    => { type: 'to_i', kind: :metric },   # ["789853"]      Number of untransmitted events/records
  'dl_uptime'           => { type: 'to_i', kind: :metric },   # ["2878431"]     Number of seconds the system has been running
  'freq_hz'             => { type: 'to_f', kind: :metric },   # "59.99"         Operating Frequency
  'i_3phsum_a'          => { type: 'to_f', kind: :metric },   # ["0.04", "0"]   AC Current (amperes)
  'i_mppt1_a'           => { type: 'to_f', kind: :metric },   # ["0.1"]         DC Current (amperes)
  'ltea_3phsum_kwh'     => { type: 'to_f', kind: :metric },   # ["905.7943"     Total Net Energy (kilowatt-hours)
  'net_ltea_3phsum_kwh' => { type: 'to_f', kind: :metric },   # ["25370.4", "0"]
  'origin'              => { type: 'to_s', kind: :metric },   # ["data_logger"]
  'p_3phsum_kw'         => { type: 'to_f', kind: :metric },   # ["0.0015"]      Average real power (kilowatts)
  'p_mpptsum_kw'        => { type: 'to_f', kind: :metric },   # ["0.0004"]      DC Power (kilowatts)
  'panid'               => { type: 'to_i', kind: :metric },   # [1446673874]
  'q_3phsum_kvar'       => { type: 'to_f', kind: :metric },   # ["-0.8082", "0"]  Reactive power (kilovolt-amp-reactive)
  's_3phsum_kva'        => { type: 'to_f', kind: :metric },   # ["0.8155", "0"]  Apparent power (kilovolt-amp)
  'stat_ind'            => { type: 'to_i', kind: :metric },   # ["0"]
  't_htsnk_degc'        => { type: 'to_f', kind: :metric },   # ["33.55"        Heatsink temperature (degrees Celsius)
  'tot_pf_rto'          => { type: 'to_f', kind: :metric },   # ["0"]           Power Factor ratio (real power / apparent power)
  'v_mppt1_v'           => { type: 'to_f', kind: :metric },   # ["46.95"        DC Voltage (volts)
  'vln_3phavg_v'        => { type: 'to_f', kind: :metric }    # ["244.07"       AC Voltage (volts)
}.freeze
# rubocop:enable Layout/HashAlignment

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

class Pvs < Thor
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

  desc 'show-measures', 'print mesures associated with pvs-monitored devices'
  def show_measures
    response = RestClient.get 'http://pvs-gateway.local/cgi-bin/dl_cgi?Command=DeviceList'
    devices = JSON.parse response
    all_keys = Set.new
    example = {}
    devices['devices'].each do |device|
      all_keys << device.keys.to_set
      device.each_key do |key|
        example[key] ||= Set.new
        example[key] << device[key]
      end
    end
    all_keys.flatten.sort.each do |key|
      print format("%<name>-21s => {type: %<type>s, kind: :tag }, # %<example>s\n",
                   { name: "'#{key}'", type: example[key].to_a[0].class, example: example[key].to_a })
    end
  end


Pvs.start