#!/usr/bin/ruby

require 'open3'
require 'uri'

TARGETS = {
  'microsoft_home' => 'https://www.microsoft.com/',
  'bing' => 'https://www.bing.com/',
  'microsoft_account' => 'https://login.live.com/',
  'microsoft_365' => 'https://www.office.com/',
  'microsoft_365_redirect' => 'https://m365.cloud.microsoft/',
  'microsoft_endpoint_service' => 'https://endpoints.office.com/endpoints/worldwide',
  'office_cdn' => 'https://res.cdn.office.net/'
}.freeze

STDOUT.sync = true

def fail_safely(message)
  warn(message)
  exit(1)
end

def probe(url)
  write_out = [
    '%{http_code}',
    '%{time_namelookup}',
    '%{time_connect}',
    '%{time_appconnect}',
    '%{time_starttransfer}',
    '%{time_total}',
    '%{num_redirects}',
    '%{ssl_verify_result}',
    '%{url_effective}'
  ].join("\t")
  environment = {
    'ALL_PROXY' => nil,
    'HTTPS_PROXY' => nil,
    'HTTP_PROXY' => nil,
    'NO_PROXY' => '*',
    'all_proxy' => nil,
    'https_proxy' => nil,
    'http_proxy' => nil,
    'no_proxy' => '*'
  }
  output, _error, status = Open3.capture3(
    environment,
    '/usr/bin/curl',
    '--silent',
    '--show-error',
    '--location',
    '--max-redirs',
    '5',
    '--connect-timeout',
    '8',
    '--max-time',
    '12',
    '--http1.1',
    '--noproxy',
    '*',
    '--user-agent',
    'FlClash-Phase1-Probe/1.0',
    '--output',
    '/dev/null',
    '--write-out',
    write_out,
    '--url',
    url
  )
  fields = output.split("\t", -1)
  fail_safely('curl returned an invalid probe summary') unless fields.length == 9

  effective_domain = begin
    host = URI.parse(fields[8]).host.to_s.downcase
    host.match?(/\A(?=.{1,253}\z)[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/) ? host : 'unknown'
  rescue URI::InvalidURIError
    'unknown'
  end

  {
    exit_code: status.exitstatus || 255,
    http_code: fields[0].to_i,
    dns_ms: (fields[1].to_f * 1000).round,
    tcp_ms: (fields[2].to_f * 1000).round,
    tls_ms: (fields[3].to_f * 1000).round,
    first_byte_ms: (fields[4].to_f * 1000).round,
    total_ms: (fields[5].to_f * 1000).round,
    redirects: fields[6].to_i,
    tls_verify: fields[7].to_i,
    effective_domain: effective_domain
  }
end

def stage(result)
  return 'http_response' if result[:http_code].positive?
  return 'tls_connected' if result[:tls_ms].positive?
  return 'tcp_connected' if result[:tcp_ms].positive?
  return 'dns_resolved' if result[:dns_ms].positive?
  return 'dns_error' if result[:exit_code] == 6
  return 'connect_error' if result[:exit_code] == 7
  return 'tls_error' if [35, 51, 58, 59, 60, 64, 66, 77, 80, 82, 83, 90, 91].include?(result[:exit_code])
  return 'timeout' if result[:exit_code] == 28

  'other_error'
end

def outcome(result)
  return 'success' if result[:exit_code].zero? && result[:http_code].positive? && result[:tls_verify].zero?
  return 'partial_http_timeout' if result[:exit_code] == 28 && result[:http_code].positive?
  return 'partial_http_tls_error' if result[:http_code].positive? && result[:tls_verify].positive?
  return 'timeout' if result[:exit_code] == 28
  return 'dns_error' if result[:exit_code] == 6
  return 'connect_error' if result[:exit_code] == 7
  return 'tls_error' if [35, 51, 58, 59, 60, 64, 66, 77, 80, 82, 83, 90, 91].include?(result[:exit_code])

  'other_error'
end

def self_test
  cases = [
    [{ exit_code: 0, http_code: 200, tls_ms: 10, tcp_ms: 5, dns_ms: 1 }, 'http_response'],
    [{ exit_code: 28, http_code: 0, tls_ms: 0, tcp_ms: 4, dns_ms: 1 }, 'tcp_connected'],
    [{ exit_code: 6, http_code: 0, tls_ms: 0, tcp_ms: 0, dns_ms: 0 }, 'dns_error'],
    [{ exit_code: 35, http_code: 0, tls_ms: 0, tcp_ms: 0, dns_ms: 1 }, 'dns_resolved']
  ]
  fail_safely('public probe self-test failed') unless cases.all? { |result, expected| stage(result) == expected }
  outcome_cases = [
    [{ exit_code: 0, http_code: 200, tls_verify: 0 }, 'success'],
    [{ exit_code: 28, http_code: 302, tls_verify: 1 }, 'partial_http_timeout']
  ]
  fail_safely('public probe outcome self-test failed') unless outcome_cases.all? do |result, expected|
    outcome(result) == expected
  end

  puts("self_test_cases=#{cases.length + outcome_cases.length}")
  puts('self_test_passed=true')
end

command = ARGV.shift || 'microsoft'
if command == 'self-test'
  fail_safely('self-test accepts no arguments') unless ARGV.empty?
  self_test
  exit
end
fail_safely('usage: macos_public_service_probe.rb microsoft [REPETITIONS] [TARGET] | self-test') unless command == 'microsoft'

repetitions = ARGV.shift || '3'
fail_safely('repetitions must be between 1 and 5') unless repetitions.match?(/\A\d+\z/) && repetitions.to_i.between?(1, 5)
requested_target = ARGV.shift
fail_safely('unknown target') if requested_target && !TARGETS.key?(requested_target)
fail_safely('unexpected extra arguments') unless ARGV.empty?

targets = requested_target ? { requested_target => TARGETS.fetch(requested_target) } : TARGETS

puts('path=tun_http1')
puts("target_count=#{targets.length}")
puts("repetitions=#{repetitions.to_i}")
targets.each do |name, url|
  host = URI.parse(url).host
  repetitions.to_i.times do |index|
    result = probe(url)
    prefix = "#{name}_#{index + 1}"
    puts("#{prefix}_domain=#{host}")
    puts("#{prefix}_stage=#{stage(result)}")
    puts("#{prefix}_outcome=#{outcome(result)}")
    puts("#{prefix}_exit_code=#{result[:exit_code]}")
    puts("#{prefix}_http_code=#{result[:http_code]}")
    puts("#{prefix}_dns_ms=#{result[:dns_ms]}")
    puts("#{prefix}_tcp_ms=#{result[:tcp_ms]}")
    puts("#{prefix}_tls_ms=#{result[:tls_ms]}")
    puts("#{prefix}_first_byte_ms=#{result[:first_byte_ms]}")
    puts("#{prefix}_total_ms=#{result[:total_ms]}")
    puts("#{prefix}_redirects=#{result[:redirects]}")
    puts("#{prefix}_tls_verify=#{result[:tls_verify]}")
    puts("#{prefix}_effective_domain=#{result[:effective_domain]}")
  end
end
