#!/usr/bin/ruby

require 'digest'
require 'fileutils'
require 'ipaddr'
require 'json'
require 'open3'
require 'tmpdir'
require 'uri'
require 'yaml'

CONFIG_PATH = File.join(
  Dir.home,
  'Library',
  'Application Support',
  'com.follow.clash',
  'config.yaml'
).freeze

def fail_safely(message)
  warn(message)
  exit(1)
end

def load_dns_config
  root = YAML.safe_load(
    File.read(CONFIG_PATH, mode: 'r:BOM|UTF-8'),
    permitted_classes: [],
    permitted_symbols: [],
    aliases: true
  )
  fail_safely('effective config root is not a mapping') unless root.is_a?(Hash)
  dns = root['dns']
  fail_safely('effective config has no DNS mapping') unless dns.is_a?(Hash)
  Marshal.load(Marshal.dump(dns))
rescue Errno::ENOENT
  fail_safely('effective config is unavailable')
rescue Psych::Exception
  fail_safely('effective config could not be parsed')
end

def minimal_config(dns, without_fallback:)
  isolated_dns = Marshal.load(Marshal.dump(dns))
  isolated_dns.delete('listen')
  if without_fallback
    isolated_dns.delete('fallback')
    isolated_dns.delete('fallback-filter')
  end
  {
    'port' => 0,
    'socks-port' => 0,
    'mixed-port' => 0,
    'redir-port' => 0,
    'tproxy-port' => 0,
    'allow-lan' => false,
    'mode' => 'direct',
    'log-level' => 'silent',
    'ipv6' => false,
    'profile' => {
      'store-selected' => false,
      'store-fake-ip' => false
    },
    'dns' => isolated_dns,
    'proxies' => [],
    'proxy-groups' => [],
    'rules' => []
  }
end

def copy_geodata(runtime_dir)
  source_root = File.dirname(CONFIG_PATH)
  ['Country.mmdb', 'geoip.db', 'geoip.metadb', 'GEOIP.metadb'].each do |name|
    source = File.join(source_root, name)
    next unless File.file?(source)

    destination = File.join(runtime_dir, name)
    next if File.exist?(destination)

    FileUtils.cp(source, destination)
    File.chmod(0o600, destination)
    return
  end
  fail_safely('required GeoIP database is unavailable')
end

def wait_for_socket(socket_path, pid)
  100.times do
    return :ready if File.socket?(socket_path)
    begin
      Process.kill(0, pid)
    rescue Errno::ESRCH
      return :exited
    end
    sleep(0.1)
  end
  :timeout
end

def print_runtime_failure_classification(output)
  normalized = output.to_s.downcase
  puts("runtime_log_present=#{!output.to_s.empty?}")
  puts("runtime_parse_error=#{normalized.include?('parse config') || normalized.include?('configuration error')}")
  puts("runtime_controller_error=#{normalized.include?('external controller') || normalized.include?('listen unix')}")
  puts("runtime_geodata_error=#{normalized.include?('geoip') || normalized.include?('mmdb') || normalized.include?('geodata')}")
  puts("runtime_failed_keyword=#{normalized.include?('failed') || normalized.include?('error')}")
  puts("runtime_download_keyword=#{normalized.include?('download')}")
  puts("runtime_listener_keyword=#{normalized.include?('listener') || normalized.include?('mixed-port')}")
  puts("runtime_permission_error=#{normalized.include?('permission denied')}")
  puts("runtime_address_in_use=#{normalized.include?('address already in use')}")
end

def classify_error(body)
  normalized = body.to_s.downcase
  return 'timeout' if normalized.include?('timeout') || normalized.include?('deadline exceeded')
  return 'refused' if normalized.include?('refused')
  return 'dns' if normalized.include?('dns') || normalized.include?('resolve')
  return 'unavailable' if normalized.include?('unavailable')

  'other'
end

def query_a(socket_path, domain)
  query = URI.encode_www_form('name' => domain, 'type' => 'A')
  output, _error, status = Open3.capture3(
    '/usr/bin/curl',
    '--silent',
    '--show-error',
    '--max-time',
    '8',
    '--unix-socket',
    socket_path,
    '--url',
    "http://localhost/dns/query?#{query}",
    '--write-out',
    "\n%{http_code}"
  )
  return { result: 'transport_error', error_class: 'timeout' } unless status.success?

  body, separator, status_code = output.rpartition("\n")
  return { result: 'invalid_response', error_class: 'other' } if separator.empty?
  unless status_code.to_i == 200
    return { result: 'error', error_class: classify_error(body) }
  end

  payload = JSON.parse(body)
  answers = payload['Answer'].is_a?(Array) ? payload['Answer'] : []
  data = answers.each_with_object([]) do |answer, result|
    result << answer['data'].to_s if answer.is_a?(Hash)
  end
  families = data.each_with_object([]) do |value, result|
    value.scan(/[0-9A-Fa-f:.]+/).each do |candidate|
      begin
        result << (IPAddr.new(candidate).ipv4? ? 4 : 6)
      rescue IPAddr::InvalidAddressError
        next
      end
    end
  end
  material = data.sort.join("\0")
  {
    result: 'success',
    error_class: 'none',
    answer_count: answers.length,
    ipv4_count: families.count(4),
    ipv6_count: families.count(6),
    answer_fingerprint: material.empty? ? 'none' : Digest::SHA256.hexdigest(material)[0, 16]
  }
rescue JSON::ParserError
  { result: 'invalid_json', error_class: 'other' }
end

def flush_dns_cache(socket_path)
  _output, _error, status = Open3.capture3(
    '/usr/bin/curl',
    '--silent',
    '--show-error',
    '--max-time',
    '5',
    '--unix-socket',
    socket_path,
    '--request',
    'POST',
    '--url',
    'http://localhost/cache/dns/flush'
  )
  fail_safely('isolated Mihomo DNS cache flush failed') unless status.success?
end

def stop_process(pid)
  Process.kill('TERM', pid)
  50.times do
    waited = Process.waitpid(pid, Process::WNOHANG)
    return if waited
    sleep(0.1)
  end
  Process.kill('KILL', pid)
  Process.waitpid(pid)
rescue Errno::ESRCH, Errno::ECHILD
  nil
end

def run_variant(binary, dns, variant, without_fallback:)
  runtime_dir = Dir.mktmpdir("flclash-phase1-dns-#{variant}-", '/tmp')
  File.chmod(0o700, runtime_dir)
  copy_geodata(runtime_dir)
  socket_path = File.join(runtime_dir, 'controller.sock')
  runtime_log_path = File.join(runtime_dir, 'runtime.log')
  runtime_log = File.open(runtime_log_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600)
  config = YAML.dump(minimal_config(dns, without_fallback: without_fallback))
  input_reader, input_writer = IO.pipe
  pid = Process.spawn(
    binary,
    '-d',
    runtime_dir,
    '-f',
    '-',
    '-ext-ctl-unix',
    socket_path,
    in: input_reader,
    out: runtime_log,
    err: runtime_log
  )
  runtime_log.close
  input_reader.close
  input_writer.write(config)
  input_writer.close
  readiness = wait_for_socket(socket_path, pid)
  unless readiness == :ready
    print_runtime_failure_classification(File.read(runtime_log_path, mode: 'r:BOM|UTF-8'))
    fail_safely("isolated Mihomo controller readiness failed: #{readiness}")
  end

  puts("variant=#{variant}")
  ['apps.apple.com', 'account.apple.com', 'www.icloud.com'].each do |domain|
    3.times do |index|
      flush_dns_cache(socket_path)
      summary = query_a(socket_path, domain)
      puts("domain=#{domain}")
      puts("round=#{index + 1}")
      puts("result=#{summary[:result]}")
      puts("error_class=#{summary[:error_class]}")
      puts("answer_count=#{summary.fetch(:answer_count, 0)}")
      puts("ipv4_count=#{summary.fetch(:ipv4_count, 0)}")
      puts("ipv6_count=#{summary.fetch(:ipv6_count, 0)}")
      puts("answer_fingerprint=#{summary.fetch(:answer_fingerprint, 'none')}")
    end
  end
ensure
  input_reader.close unless input_reader.nil? || input_reader.closed?
  input_writer.close unless input_writer.nil? || input_writer.closed?
  runtime_log.close if runtime_log && !runtime_log.closed?
  stop_process(pid) if pid
  FileUtils.remove_entry_secure(runtime_dir) if runtime_dir && Dir.exist?(runtime_dir)
end

binary = ARGV.shift
fail_safely('usage: macos_dns_fallback_isolation.rb /absolute/path/to/mihomo') unless ARGV.empty?
fail_safely('isolated Mihomo binary is unavailable') unless binary && File.executable?(binary)
fail_safely('isolated Mihomo binary path must be absolute') unless binary.start_with?('/')

dns = load_dns_config
run_variant(binary, dns, 'original_dns', without_fallback: false)
run_variant(binary, dns, 'without_fallback', without_fallback: true)
