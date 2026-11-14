#!/usr/bin/ruby

require 'json'
require 'open3'
require 'digest'
require 'ipaddr'
require 'net/http'
require 'uri'
require 'yaml'

CONFIG_PATH = ENV.fetch(
  'FLCLASH_EFFECTIVE_CONFIG',
  File.join(Dir.home, 'Library', 'Application Support', 'com.follow.clash', 'config.yaml')
).freeze

def fail_safely(message)
  warn(message)
  exit(1)
end

def load_effective_config
  raw = File.read(CONFIG_PATH, mode: 'r:BOM|UTF-8')
  config = YAML.safe_load(raw, permitted_classes: [], permitted_symbols: [], aliases: true)
  fail_safely('effective config root is not a mapping') unless config.is_a?(Hash)
  config
rescue Errno::ENOENT
  fail_safely('effective config is unavailable')
rescue Psych::Exception
  fail_safely('effective config could not be parsed')
end

def local_tcp_endpoint(controller)
  value = controller.to_s.strip
  fail_safely('external controller is unavailable') if value.empty?

  value = "127.0.0.1#{value}" if value.start_with?(':')
  uri = URI.parse(value.include?('://') ? value : "http://#{value}")
  host = uri.host
  port = uri.port
  allowed_hosts = ['127.0.0.1', 'localhost', '::1', '0.0.0.0', '::']
  fail_safely('refusing a non-local external controller') unless allowed_hosts.include?(host)
  fail_safely('external controller port is invalid') unless port.between?(1, 65_535)

  request_host = ['0.0.0.0', ''].include?(host) ? '127.0.0.1' : host
  request_host = '::1' if host == '::'
  rendered_host = request_host.include?(':') ? "[#{request_host}]" : request_host
  scope = ['127.0.0.1', 'localhost', '::1'].include?(host) ? 'loopback' : 'wildcard'
  ["http://#{rendered_host}:#{port}/configs", scope, port == 9090 ? 'default_9090' : 'other']
rescue URI::InvalidURIError
  fail_safely('external controller address is invalid')
end

def controller_for(config)
  unix_socket = config['external-controller-unix'].to_s.strip
  unless unix_socket.empty?
    socket_path = if unix_socket.start_with?('/')
                    unix_socket
                  else
                    File.expand_path(unix_socket, File.dirname(CONFIG_PATH))
                  end
    fail_safely('external controller unix socket is unavailable') unless File.socket?(socket_path)
    return {
      kind: 'unix',
      url: 'http://localhost/configs',
      socket: socket_path,
      secret: '',
      scope: 'filesystem_socket',
      port_class: 'none'
    }
  end

  tcp_controller = config['external-controller'].to_s.strip
  if tcp_controller.empty? && ENV['FLCLASH_PHASE1_ALLOW_DEFAULT_CONTROLLER'] == '1'
    return {
      kind: 'tcp',
      url: 'http://127.0.0.1:9090/configs',
      socket: nil,
      secret: '',
      scope: 'loopback',
      port_class: 'default_9090'
    }
  end

  url, scope, port_class = local_tcp_endpoint(tcp_controller)

  {
    kind: 'tcp',
    url: url,
    socket: nil,
    secret: config['secret'].to_s,
    scope: scope,
    port_class: port_class
  }
end

def curl_config(secret)
  return '' if secret.empty?
  fail_safely('controller secret contains unsupported newline characters') if secret.match?(/[\r\n]/)

  escaped = secret.gsub('\\', '\\\\').gsub('"', '\\"')
  "header = \"Authorization: Bearer #{escaped}\"\n"
end

def request(controller, method:, payload: nil, path: nil)
  request_url = if path
                  controller[:url].sub(%r{/configs\z}, path)
                else
                  controller[:url]
                end
  arguments = [
    '/usr/bin/curl',
    '--silent',
    '--show-error',
    '--max-time',
    '10',
    '--config',
    '-',
    '--request',
    method,
    '--url',
    request_url,
    '--write-out',
    "\n%{http_code}"
  ]
  arguments.concat(['--unix-socket', controller[:socket]]) if controller[:socket]
  arguments.concat(['--header', 'Content-Type: application/json']) if payload
  arguments.concat(['--data-binary', JSON.generate(payload)]) if payload

  output, _error, status = Open3.capture3(
    *arguments,
    stdin_data: curl_config(controller[:secret])
  )
  fail_safely('local controller request failed') unless status.success?

  body, separator, status_code = output.rpartition("\n")
  fail_safely('local controller returned an invalid response') if separator.empty?
  [status_code.to_i, body]
end

def sensitive_tcp_request(controller, method:, path:, payload: nil)
  fail_safely('sensitive controller request requires loopback TCP') unless controller[:kind] == 'tcp'
  base_uri = URI.parse(controller[:url])
  http = Net::HTTP.new(base_uri.host, base_uri.port)
  http.open_timeout = 5
  http.read_timeout = 30
  request_class = case method
                  when 'GET'
                    Net::HTTP::Get
                  when 'PUT'
                    Net::HTTP::Put
                  else
                    fail_safely('unsupported sensitive controller request method')
                  end
  http_request = request_class.new(path)
  unless controller[:secret].empty?
    fail_safely('controller secret contains unsupported newline characters') if controller[:secret].match?(/[\r\n]/)
    http_request['Authorization'] = "Bearer #{controller[:secret]}"
  end
  if payload
    http_request['Content-Type'] = 'application/json'
    http_request.body = JSON.generate(payload)
  end
  response = http.start { |client| client.request(http_request) }
  [response.code.to_i, response.body.to_s]
rescue URI::InvalidURIError, SocketError, SystemCallError, Timeout::Error
  fail_safely('sensitive loopback controller request failed')
end

def connection_route_class(chains)
  normalized = chains.map { |value| value.to_s.upcase }.join(' ')
  return 'direct' if normalized.match?(/(?:\A|[\[\],\s])DIRECT(?:\z|[\[\],\s])/)
  return 'reject' if normalized.match?(/(?:\A|[\[\],\s])REJECT(?:-DROP)?(?:\z|[\[\],\s])/)

  'proxy'
end

def dns_event_summary(payload)
  unless payload.start_with?('[DNS]')
    return {
      kind: 'none',
      query_type: 'none',
      has_ipv4: false,
      has_ipv6: false,
      ipv4_count: 0,
      ipv6_count: 0,
      source_class: 'none',
      source_fingerprint: 'none'
    }
  end

  raw_query_type = payload[/\A\[DNS\]\s+resolve\s+\S+\s+(\S+)\s+from\s/, 1].to_s.upcase
  query_type = case raw_query_type
               when 'A'
                 'a'
               when 'AAAA'
                 'aaaa'
               when /HTTPS|SVCB|65/
                 'https'
               else
                 'other'
               end
  kind = case payload
         when /\A\[DNS\]\s+resolve\s+/
           'query_start'
         when /\A\[DNS\]\s+cache hit\s+.*\s+-->\s+/
           'cache_hit'
         when /\A\[DNS\]\s+.*\s+-->\s+/
           'response'
         when /\A\[DNS\]\s+dial\s+/
           'outbound_dial_error'
         else
           payload.include?(' error:') ? 'error' : 'other'
         end

  answer = if ['cache_hit', 'response'].include?(kind)
             payload.split('-->', 2).last.to_s.split(' from ', 2).first.to_s
           else
             ''
           end
  families = answer.scan(/[0-9A-Fa-f:.]+/).each_with_object([]) do |candidate, result|
    begin
      result << (IPAddr.new(candidate).ipv4? ? 4 : 6)
    rescue IPAddr::InvalidAddressError
      next
    end
  end
  source = if payload.include?(' from ')
             payload.split(' from ', 2).last.to_s.split(' error:', 2).first.to_s.strip
           else
             ''
           end
  source_class = case source.downcase
                 when /\Ahttps:/
                   'doh'
                 when /\Atls:/
                   'dot'
                 when /\Aquic:/
                   'doq'
                 when /\Adhcp:/
                   'dhcp'
                 when /\Asystem\z/
                   'system'
                 when /\A\z/
                   'none'
                 else
                   'plain'
                 end
  {
    kind: kind,
    query_type: query_type,
    has_ipv4: families.include?(4),
    has_ipv6: families.include?(6),
    ipv4_count: families.count(4),
    ipv6_count: families.count(6),
    source_class: source_class,
    source_fingerprint: source.empty? ? 'none' : Digest::SHA256.hexdigest(source)[0, 16]
  }
end

def trace_domain_connections(controller, domain)
  normalized_domain = domain.to_s.strip.downcase
  unless normalized_domain.match?(/\A(?=.{1,253}\z)[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/)
    fail_safely('connections-domain requires a valid public domain name')
  end

  status_code, body = request(controller, method: 'GET', path: '/connections')
  fail_safely('local controller connections GET failed') unless status_code == 200

  payload = JSON.parse(body)
  connections = payload['connections']
  fail_safely('local controller response has no connections list') unless connections.is_a?(Array)

  traces = connections.each_with_object([]) do |connection, result|
    next unless connection.is_a?(Hash)

    metadata = connection['metadata']
    next unless metadata.is_a?(Hash)
    next unless metadata['host'].to_s.downcase == normalized_domain

    chains = connection['chains'].is_a?(Array) ? connection['chains'] : []
    chain_material = chains.map(&:to_s).join("\0")
    result << {
      inbound_type: metadata['type'].to_s.downcase,
      network: metadata['network'].to_s.downcase,
      rule_type: connection['rule'].to_s,
      route_class: connection_route_class(chains),
      chain_fingerprint: Digest::SHA256.hexdigest(chain_material)[0, 16]
    }
  end

  unique_traces = traces.uniq.sort_by do |trace|
    [
      trace[:inbound_type],
      trace[:network],
      trace[:rule_type],
      trace[:route_class],
      trace[:chain_fingerprint]
    ]
  end

  puts("domain=#{normalized_domain}")
  puts("connection_matches=#{traces.length}")
  puts("unique_traces=#{unique_traces.length}")
  unique_traces.each_with_index do |trace, index|
    prefix = "trace_#{index + 1}"
    puts("#{prefix}_inbound_type=#{trace[:inbound_type]}")
    puts("#{prefix}_network=#{trace[:network]}")
    puts("#{prefix}_rule_type=#{trace[:rule_type]}")
    puts("#{prefix}_route_class=#{trace[:route_class]}")
    puts("#{prefix}_chain_fingerprint=#{trace[:chain_fingerprint]}")
  end
rescue JSON::ParserError
  fail_safely('local controller connections response is not valid JSON')
end

def classify_error(payload)
  normalized = payload.downcase
  return 'timeout' if normalized.include?('timeout') || normalized.include?('deadline exceeded')
  return 'tls' if normalized.include?('tls') || normalized.include?('handshake') || normalized.include?('certificate')
  return 'refused' if normalized.include?('refused')
  return 'reset' if normalized.include?('reset')
  return 'unreachable' if normalized.include?('unreachable') || normalized.include?('no route')
  return 'dns' if normalized.include?('lookup') || normalized.include?('resolve') || normalized.include?('dns')
  return 'canceled' if normalized.include?('context canceled')
  return 'eof' if normalized.include?('eof')

  'other'
end

def sanitized_log_event(level, payload)
  network = payload[/\A\[([^\]]+)\]/, 1].to_s.downcase
  rule_type = payload[/\(match ([^\/\)]+)\//, 1]
  rule_type ||= payload[/\bmatch ([A-Za-z0-9_-]+)/, 1]

  route_material_kind = if payload.include?(' using ')
                          'connected_chain'
                        elsif payload.include?(' (match ')
                          'dial_target'
                        else
                          'none'
                        end
  route_material = case route_material_kind
                   when 'connected_chain'
                     payload.split(' using ', 2).last.to_s
                   when 'dial_target'
                     payload.sub(/\A\[[^\]]+\]\s+dial\s+/, '').split(' (match ', 2).first.to_s
                   else
                     ''
                   end
  route_class = if route_material_kind == 'none'
                  'none'
                elsif route_material_kind == 'dial_target' &&
                      !['DIRECT', 'REJECT', 'REJECT-DROP'].include?(route_material.upcase)
                  'unresolved'
                else
                  connection_route_class([route_material])
                end
  dns_summary = dns_event_summary(payload)
  event_kind = if payload.include?(' error:')
                 'dial_error'
               elsif payload.include?(' using ')
                 'connected'
               else
                 'other'
               end

  {
    level: level.to_s.downcase,
    network: network,
    event_kind: event_kind,
    rule_type: rule_type.to_s,
    route_class: route_class,
    route_material_kind: route_material_kind,
    route_fingerprint: Digest::SHA256.hexdigest(route_material)[0, 16],
    error_class: event_kind == 'dial_error' ? classify_error(payload) : 'none',
    dns_event_kind: dns_summary[:kind],
    dns_query_type: dns_summary[:query_type],
    dns_has_ipv4: dns_summary[:has_ipv4],
    dns_has_ipv6: dns_summary[:has_ipv6],
    dns_ipv4_count: dns_summary[:ipv4_count],
    dns_ipv6_count: dns_summary[:ipv6_count],
    dns_source_class: dns_summary[:source_class],
    dns_source_fingerprint: dns_summary[:source_fingerprint]
  }
end

def stream_domain_logs(controller, domain, seconds)
  normalized_domain = domain.to_s.strip.downcase
  unless normalized_domain.match?(/\A(?=.{1,253}\z)[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/)
    fail_safely('logs-domain requires a valid public domain name')
  end
  unless seconds.to_s.match?(/\A[0-9]+\z/) && seconds.to_i.between?(1, 60)
    fail_safely('logs-domain seconds must be between 1 and 60')
  end

  request_url = controller[:url].sub(%r{/configs\z}, '/logs?level=debug')
  arguments = [
    '/usr/bin/curl',
    '--silent',
    '--show-error',
    '--no-buffer',
    '--max-time',
    seconds.to_i.to_s,
    '--config',
    '-',
    '--url',
    request_url
  ]
  arguments.concat(['--unix-socket', controller[:socket]]) if controller[:socket]

  events = []
  status = nil
  Open3.popen3(*arguments) do |stdin, stdout, error, wait_thread|
    stdin.write(curl_config(controller[:secret]))
    stdin.close
    error_drain = Thread.new { error.read }
    stdout.each_line do |line|
      begin
        parsed = JSON.parse(line)
      rescue JSON::ParserError
        next
      end
      payload = parsed['payload'].to_s
      next unless payload.downcase.include?(normalized_domain)

      events << sanitized_log_event(parsed['type'], payload)
    end
    error_drain.join
    status = wait_thread.value
  end
  unless status.success? || status.exitstatus == 28
    fail_safely('local controller log stream failed')
  end

  unique_events = events.uniq.sort_by do |event|
    [
      event[:level],
      event[:network],
      event[:event_kind],
      event[:rule_type],
      event[:route_class],
      event[:route_fingerprint],
      event[:error_class]
    ]
  end
  puts("domain=#{normalized_domain}")
  puts("log_matches=#{events.length}")
  puts("unique_events=#{unique_events.length}")
  unique_events.each_with_index do |event, index|
    prefix = "event_#{index + 1}"
    event.each { |key, value| puts("#{prefix}_#{key}=#{value}") }
  end
end

APPLE_PUBLIC_SUFFIXES = [
  'apple.com',
  'apple.com.cn',
  'icloud.com',
  'icloud.com.cn',
  'icloud-content.com',
  'apple-cloudkit.com',
  'apple-dns.net',
  'cdn-apple.com',
  'mzstatic.com',
  'aaplimg.com',
  'me.com',
  'mac.com'
].freeze

NETWORK_DETECTION_PUBLIC_DOMAINS = [
  'ipwho.is',
  'api.myip.com',
  'ipapi.co',
  'ident.me',
  'ip-api.com',
  'api.ip.sb',
  'ipinfo.io'
].freeze

def network_detection_public_domains(payload)
  payload.to_s.downcase.scan(
    /\b(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\b/
  ).select { |domain| NETWORK_DETECTION_PUBLIC_DOMAINS.include?(domain) }.uniq
end

def self_test_network_detection_filter
  cases = {
    'all_expected' => [NETWORK_DETECTION_PUBLIC_DOMAINS.join(' '), NETWORK_DETECTION_PUBLIC_DOMAINS],
    'case_and_duplicate' => ['IPWHO.IS then ipwho.is', ['ipwho.is']],
    'lookalike_prefix' => ['evilipwho.is', []],
    'lookalike_suffix' => ['ipwho.is.evil', []],
    'numeric_address' => ['connect 127.0.0.1:443', []]
  }
  failures = cases.each_with_object([]) do |(name, (payload, expected)), result|
    result << name unless network_detection_public_domains(payload) == expected
  end
  fail_safely('network-detection public-domain filter self-test failed') unless failures.empty?

  puts("self_test_cases=#{cases.length}")
  puts('self_test_passed=true')
end

def stream_network_detection_logs(controller, seconds)
  unless seconds.to_s.match?(/\A[0-9]+\z/) && seconds.to_i.between?(1, 60)
    fail_safely('logs-network-detection seconds must be between 1 and 60')
  end

  request_url = controller[:url].sub(%r{/configs\z}, '/logs?level=debug')
  arguments = [
    '/usr/bin/curl',
    '--silent',
    '--show-error',
    '--no-buffer',
    '--max-time',
    seconds.to_i.to_s,
    '--config',
    '-',
    '--url',
    request_url
  ]
  arguments.concat(['--unix-socket', controller[:socket]]) if controller[:socket]

  started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  events = []
  status = nil
  Open3.popen3(*arguments) do |stdin, stdout, error, wait_thread|
    stdin.write(curl_config(controller[:secret]))
    stdin.close
    error_drain = Thread.new { error.read }
    stdout.each_line do |line|
      begin
        parsed = JSON.parse(line)
      rescue JSON::ParserError
        next
      end
      payload = parsed['payload'].to_s
      second = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).floor
      network_detection_public_domains(payload).each do |domain|
        event = sanitized_log_event(parsed['type'], payload)
        events << {
          domain: domain,
          second: second,
          event_kind: event[:event_kind],
          dns_event_kind: event[:dns_event_kind],
          error_class: event[:error_class]
        }
      end
    end
    error_drain.join
    status = wait_thread.value
  end
  unless status.success? || status.exitstatus == 28
    fail_safely('local controller network-detection log stream failed')
  end

  puts("capture_seconds=#{seconds.to_i}")
  puts("log_matches=#{events.length}")
  puts("active_second_buckets=#{events.map { |event| event[:second] }.uniq.length}")
  NETWORK_DETECTION_PUBLIC_DOMAINS.each_with_index do |domain, index|
    domain_events = events.select { |event| event[:domain] == domain }
    next if domain_events.empty?

    prefix = "domain_#{index + 1}"
    seconds_seen = domain_events.map { |event| event[:second] }.uniq.sort
    puts("#{prefix}_name=#{domain}")
    puts("#{prefix}_matches=#{domain_events.length}")
    puts("#{prefix}_active_second_buckets=#{seconds_seen.length}")
    puts("#{prefix}_first_second=#{seconds_seen.first}")
    puts("#{prefix}_last_second=#{seconds_seen.last}")
    domain_events.group_by { |event| event[:event_kind] }.sort.each do |kind, values|
      puts("#{prefix}_event_kind[#{kind}]=#{values.length}")
    end
    domain_events.group_by { |event| event[:dns_event_kind] }.sort.each do |kind, values|
      puts("#{prefix}_dns_event_kind[#{kind}]=#{values.length}")
    end
    domain_events.group_by { |event| event[:error_class] }.sort.each do |kind, values|
      puts("#{prefix}_error_class[#{kind}]=#{values.length}")
    end
  end
end

def apple_public_domains(payload)
  payload.to_s.downcase.scan(
    /\b(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\b/
  ).select do |domain|
    APPLE_PUBLIC_SUFFIXES.any? do |suffix|
      domain == suffix || domain.end_with?(".#{suffix}")
    end
  end.uniq
end

def self_test_apple_filter
  cases = {
    'root_domain' => ['apple.com', ['apple.com']],
    'nested_domain' => ['TCP connect to setup.icloud.com:443', ['setup.icloud.com']],
    'regional_domain' => ['gateway.icloud.com.cn', ['gateway.icloud.com.cn']],
    'case_and_duplicate' => ['APPLE.COM then apple.com', ['apple.com']],
    'lookalike_prefix' => ['evilapple.com', []],
    'lookalike_suffix' => ['apple.com.evil', []],
    'numeric_address' => ['connect 127.0.0.1:443', []]
  }
  failures = cases.map do |name, (payload, expected)|
    name unless apple_public_domains(payload) == expected
  end.compact
  fail_safely('Apple public-domain filter self-test failed') unless failures.empty?

  dns_event = sanitized_log_event(
    'debug',
    '[DNS] resolve setup.icloud.com A from https://redacted.invalid'
  )
  unless dns_event[:route_material_kind] == 'none' && dns_event[:route_class] == 'none'
    fail_safely('Apple log sanitization self-test failed')
  end

  puts("self_test_cases=#{cases.length}")
  puts('self_test_event_checks=1')
  puts('self_test_passed=true')
end

def stream_apple_logs(controller, seconds)
  unless seconds.to_s.match?(/\A[0-9]+\z/) && seconds.to_i.between?(1, 60)
    fail_safely('logs-apple seconds must be between 1 and 60')
  end

  request_url = controller[:url].sub(%r{/configs\z}, '/logs?level=debug')
  arguments = [
    '/usr/bin/curl',
    '--silent',
    '--show-error',
    '--no-buffer',
    '--max-time',
    seconds.to_i.to_s,
    '--config',
    '-',
    '--url',
    request_url
  ]
  arguments.concat(['--unix-socket', controller[:socket]]) if controller[:socket]

  events = []
  status = nil
  Open3.popen3(*arguments) do |stdin, stdout, error, wait_thread|
    stdin.write(curl_config(controller[:secret]))
    stdin.close
    error_drain = Thread.new { error.read }
    stdout.each_line do |line|
      begin
        parsed = JSON.parse(line)
      rescue JSON::ParserError
        next
      end
      payload = parsed['payload'].to_s
      apple_public_domains(payload).each do |domain|
        events << sanitized_log_event(parsed['type'], payload).merge(domain: domain)
      end
    end
    error_drain.join
    status = wait_thread.value
  end
  unless status.success? || status.exitstatus == 28
    fail_safely('local controller Apple log stream failed')
  end

  unique_events = events.uniq.sort_by do |event|
    [
      event[:domain],
      event[:level],
      event[:network],
      event[:event_kind],
      event[:rule_type],
      event[:route_class],
      event[:route_fingerprint],
      event[:error_class]
    ]
  end
  puts("capture_seconds=#{seconds.to_i}")
  puts("log_matches=#{events.length}")
  puts("unique_domains=#{events.map { |event| event[:domain] }.uniq.length}")
  puts("unique_events=#{unique_events.length}")
  unique_events.each_with_index do |event, index|
    prefix = "event_#{index + 1}"
    puts("#{prefix}_domain=#{event[:domain]}")
    event.each do |key, value|
      next if key == :domain

      puts("#{prefix}_#{key}=#{value}")
    end
  end
end

def normalize_public_domain(value, command)
  normalized = value.to_s.strip.downcase
  unless normalized.match?(/\A(?=.{1,253}\z)[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/)
    fail_safely("#{command} requires a valid public domain name")
  end
  normalized
end

def simple_domain_rule_matches?(rule, domain)
  return false unless rule.is_a?(Hash)
  return false if rule.dig('extra', 'disabled') == true

  type = rule['type'].to_s.downcase.gsub(/[-_]/, '')
  payload = rule['payload'].to_s.strip.downcase
  case type
  when 'domain'
    domain == payload
  when 'domainsuffix'
    suffix = payload.sub(/\A\+\./, '').sub(/\A\./, '')
    !suffix.empty? && (domain == suffix || domain.end_with?(".#{suffix}"))
  when 'domainkeyword'
    !payload.empty? && domain.include?(payload)
  when 'match'
    true
  else
    false
  end
end

def resolve_simple_domain_rule(controller, domain)
  status_code, body = request(controller, method: 'GET', path: '/rules')
  fail_safely('local controller rules GET failed') unless status_code == 200

  payload = JSON.parse(body)
  rules = payload['rules']
  fail_safely('local controller response has no rules list') unless rules.is_a?(Array)

  rule = rules.find { |candidate| simple_domain_rule_matches?(candidate, domain) }
  fail_safely('no ordered simple domain rule matched the requested domain') unless rule
  target = rule['proxy'].to_s
  fail_safely('matched rule has no target') if target.empty?

  {
    type: rule['type'].to_s,
    payload_fingerprint: Digest::SHA256.hexdigest(rule['payload'].to_s)[0, 16],
    target: target
  }
rescue JSON::ParserError
  fail_safely('local controller rules response is not valid JSON')
end

def proxy_delay_result(controller, proxy_name, domain)
  encoded_name = URI.encode_www_form_component(proxy_name).gsub('+', '%20')
  query = URI.encode_www_form(
    'url' => "https://#{domain}/",
    'timeout' => '7000',
    'expected' => '200-499'
  )
  status_code, body = request(
    controller,
    method: 'GET',
    path: "/proxies/#{encoded_name}/delay?#{query}"
  )
  case status_code
  when 200
    payload = JSON.parse(body)
    delay = payload['delay']
    fail_safely('local controller delay response has no numeric delay') unless delay.is_a?(Numeric)
    { result: 'success', delay_ms: delay.to_i }
  when 504
    { result: 'timeout', delay_ms: 0 }
  when 503
    { result: 'unavailable', delay_ms: 0 }
  when 404
    { result: 'target_not_found', delay_ms: 0 }
  else
    { result: "http_#{status_code}", delay_ms: 0 }
  end
rescue JSON::ParserError
  fail_safely('local controller delay response is not valid JSON')
end

def rule_target_summary(controller, domain)
  normalized_domain = normalize_public_domain(domain, 'rule-target-domain')
  rule = resolve_simple_domain_rule(controller, normalized_domain)
  encoded_name = URI.encode_www_form_component(rule[:target]).gsub('+', '%20')
  status_code, body = request(controller, method: 'GET', path: "/proxies/#{encoded_name}")
  fail_safely('local controller rule target GET failed') unless status_code == 200

  payload = JSON.parse(body)
  members = payload['all'].is_a?(Array) ? payload['all'].map(&:to_s) : []
  current = payload['now'].to_s
  puts("domain=#{normalized_domain}")
  puts("rule_type=#{rule[:type]}")
  puts("rule_payload_fingerprint=#{rule[:payload_fingerprint]}")
  puts("target_class=#{connection_route_class([rule[:target]])}")
  puts("target_fingerprint=#{Digest::SHA256.hexdigest(rule[:target])[0, 16]}")
  puts("target_type=#{payload['type'].to_s.downcase}")
  puts("member_count=#{members.length}")
  puts("has_direct_member=#{members.include?('DIRECT')}")
  puts("current_is_direct=#{current == 'DIRECT'}")
  puts("current_selection_fingerprint=#{current.empty? ? 'none' : Digest::SHA256.hexdigest(current)[0, 16]}")
rescue JSON::ParserError
  fail_safely('local controller rule target response is not valid JSON')
end

def dns_query_summary(controller, domain, query_type)
  query = URI.encode_www_form('name' => domain, 'type' => query_type)
  status_code, body = request(controller, method: 'GET', path: "/dns/query?#{query}")
  unless status_code == 200
    return {
      query_type: query_type.downcase,
      result: 'error',
      error_class: classify_error(body),
      answer_count: 0,
      ipv4_count: 0,
      ipv6_count: 0,
      has_ipv4_hint: false,
      has_ipv6_hint: false,
      answer_fingerprint: 'none'
    }
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
  normalized_data = data.sort.join("\0")
  {
    query_type: query_type.downcase,
    result: 'success',
    error_class: 'none',
    answer_count: answers.length,
    ipv4_count: families.count(4),
    ipv6_count: families.count(6),
    has_ipv4_hint: data.any? { |value| value.downcase.include?('ipv4hint') },
    has_ipv6_hint: data.any? { |value| value.downcase.include?('ipv6hint') },
    answer_fingerprint: normalized_data.empty? ? 'none' : Digest::SHA256.hexdigest(normalized_data)[0, 16]
  }
rescue JSON::ParserError
  fail_safely('local controller DNS response is not valid JSON')
end

def dns_domain_summary(controller, domain, requested_type = nil)
  normalized_domain = normalize_public_domain(domain, 'dns-domain')
  query_types = requested_type ? [requested_type.upcase] : ['A', 'AAAA', 'HTTPS']
  unless query_types.all? { |query_type| ['A', 'AAAA', 'HTTPS'].include?(query_type) }
    fail_safely('dns-domain type must be A, AAAA, or HTTPS')
  end
  puts("domain=#{normalized_domain}")
  query_types.each do |query_type|
    summary = dns_query_summary(controller, normalized_domain, query_type)
    prefix = "dns_#{summary[:query_type]}"
    summary.each do |key, value|
      next if key == :query_type

      puts("#{prefix}_#{key}=#{value}")
    end
  end
end

def flush_dns_cache(controller)
  status_code, = request(controller, method: 'POST', path: '/cache/dns/flush')
  fail_safely('local controller DNS cache flush failed') unless [200, 204].include?(status_code)
  puts('dns_cache_flushed=true')
end

def selector_selections(controller)
  status_code, body = sensitive_tcp_request(controller, method: 'GET', path: '/proxies')
  fail_safely('local controller proxies GET failed') unless status_code == 200
  payload = JSON.parse(body)
  proxies = payload['proxies']
  fail_safely('local controller proxies response is invalid') unless proxies.is_a?(Hash)

  proxies.each_with_object({}) do |(name, proxy), result|
    next unless proxy.is_a?(Hash)
    next unless proxy['type'].to_s.downcase == 'selector'

    current = proxy['now'].to_s
    result[name.to_s] = current unless current.empty?
  end
rescue JSON::ParserError
  fail_safely('local controller proxies response is not valid JSON')
end

def restore_selector_selections(controller, selections)
  restored = 0
  selections.each do |name, current|
    encoded_name = URI.encode_www_form_component(name).gsub('+', '%20')
    status_code = nil
    10.times do
      status_code, = sensitive_tcp_request(
        controller,
        method: 'PUT',
        path: "/proxies/#{encoded_name}",
        payload: { 'name' => current }
      )
      break if status_code == 204

      sleep(0.5)
    end
    fail_safely('selector restoration failed') unless status_code == 204
    restored += 1
  end
  restored
end

def reload_config_payload(controller, config)
  status_code, = sensitive_tcp_request(
    controller,
    method: 'PUT',
    path: '/configs?force=true',
    payload: { 'payload' => YAML.dump(config) }
  )
  fail_safely('local controller config reload failed') unless status_code == 204
end

def set_selector_sensitive(controller, name, selection)
  encoded_name = URI.encode_www_form_component(name).gsub('+', '%20')
  status_code, = sensitive_tcp_request(
    controller,
    method: 'PUT',
    path: "/proxies/#{encoded_name}",
    payload: { 'name' => selection }
  )
  fail_safely('selector update failed') unless status_code == 204

  status_code, body = sensitive_tcp_request(
    controller,
    method: 'GET',
    path: "/proxies/#{encoded_name}"
  )
  fail_safely('selector verification GET failed') unless status_code == 200
  payload = JSON.parse(body)
  fail_safely('selector verification failed') unless payload['now'].to_s == selection
rescue JSON::ParserError
  fail_safely('selector verification response is not valid JSON')
end

def selector_has_direct?(controller, name)
  encoded_name = URI.encode_www_form_component(name).gsub('+', '%20')
  status_code, body = sensitive_tcp_request(
    controller,
    method: 'GET',
    path: "/proxies/#{encoded_name}"
  )
  fail_safely('selector capability GET failed') unless status_code == 200
  payload = JSON.parse(body)
  payload['type'].to_s.downcase == 'selector' &&
    payload['all'].is_a?(Array) &&
    payload['all'].include?('DIRECT')
rescue JSON::ParserError
  fail_safely('selector capability response is not valid JSON')
end

def tun_http_probe(url)
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
    "%{http_code}\t%{time_total}\t%{ssl_verify_result}",
    '--url',
    url
  )
  fields = output.split("\t", -1)
  fail_safely('functional HTTP probe returned an invalid summary') unless fields.length == 3
  exit_code = status.exitstatus || 255
  http_code = fields[0].to_i
  tls_verify = fields[2].to_i
  outcome = if exit_code.zero? && http_code.positive? && tls_verify.zero?
              'success'
            elsif exit_code == 28
              'timeout'
            else
              'error'
            end
  {
    outcome: outcome,
    exit_code: exit_code,
    http_code: http_code,
    total_ms: (fields[1].to_f * 1000).round,
    tls_verify: tls_verify
  }
end

def microsoft_dns_no_fallback_ab(controller, config)
  dns = config['dns']
  fail_safely('effective config has no DNS mapping') unless dns.is_a?(Hash)
  fallback = dns['fallback']
  fail_safely('effective config has no DNS fallback list') unless fallback.is_a?(Array) && !fallback.empty?
  fail_safely('effective config has no DNS fallback filter') unless dns['fallback-filter'].is_a?(Hash)

  initial_state = read_state(controller)
  fail_safely('DNS fallback A/B requires enabled mixed TUN') unless initial_state[:enable] && initial_state[:stack] == 'mixed'
  selections = selector_selections(controller)
  rule_targets = MICROSOFT_TUN_TEST_DOMAINS.map do |domain|
    resolve_simple_domain_rule(controller, domain)[:target]
  end.uniq
  fail_safely('Microsoft test domains do not share one rule target') unless rule_targets.length == 1
  microsoft_selector = rule_targets.first
  fail_safely('Microsoft rule target has no DIRECT member') unless selector_has_direct?(controller, microsoft_selector)
  variant = Marshal.load(Marshal.dump(config))
  variant['dns'].delete('fallback')
  variant['dns'].delete('fallback-filter')

  puts("baseline_fallback_count=#{fallback.length}")
  puts('baseline_fallback_filter_present=true')
  puts("selector_snapshot_count=#{selections.length}")
  begin
    reload_config_payload(controller, variant)
    restored_variant_selectors = restore_selector_selections(controller, selections)
    sleep(2)
    variant_state = read_state(controller)
    fail_safely('no-fallback variant changed TUN enable') unless variant_state[:enable]
    fail_safely('no-fallback variant changed TUN stack') unless variant_state[:stack] == initial_state[:stack]
    fail_safely('no-fallback variant changed live inet6 state') unless variant_state[:inet6_count] == initial_state[:inet6_count]
    flush_dns_cache(controller)

    puts('variant=no_fallback')
    puts("variant_selector_restore_count=#{restored_variant_selectors}")
    puts("variant_tun_enable=#{variant_state[:enable]}")
    puts("variant_stack=#{variant_state[:stack]}")
    puts("variant_inet6_count=#{variant_state[:inet6_count]}")
    MICROSOFT_TUN_TEST_DOMAINS.each do |domain|
      dns_result = dns_query_summary(controller, domain, 'A')
      delay_result = proxy_delay_result(controller, 'DIRECT', domain)
      puts("variant_dns_domain=#{domain}")
      puts("variant_dns_result=#{dns_result[:result]}")
      puts("variant_dns_error_class=#{dns_result[:error_class]}")
      puts("variant_dns_answer_count=#{dns_result[:answer_count]}")
      puts("variant_dns_ipv4_count=#{dns_result[:ipv4_count]}")
      puts("variant_urltest_domain=#{domain}")
      puts("variant_urltest_result=#{delay_result[:result]}")
      puts("variant_delay_ms=#{delay_result[:delay_ms]}")
    end
    set_selector_sensitive(controller, microsoft_selector, 'DIRECT')
    puts('variant_microsoft_selector_direct=true')
    MICROSOFT_TUN_HTTP_TARGETS.each do |name, url|
      result = tun_http_probe(url)
      puts("functional_target=#{name}")
      puts("functional_outcome=#{result[:outcome]}")
      puts("functional_exit_code=#{result[:exit_code]}")
      puts("functional_http_code=#{result[:http_code]}")
      puts("functional_total_ms=#{result[:total_ms]}")
      puts("functional_tls_verify=#{result[:tls_verify]}")
    end
  ensure
    reload_config_payload(controller, config)
    restored_selectors = restore_selector_selections(controller, selections)
    sleep(2)
    restored_state = read_state(controller)
    flush_dns_cache(controller)
    puts("restored_selector_count=#{restored_selectors}")
    puts("restored_tun_enable=#{restored_state[:enable]}")
    puts("restored_stack=#{restored_state[:stack]}")
    puts("restored_inet6_present=#{restored_state[:inet6_present]}")
    puts("restored_inet6_count=#{restored_state[:inet6_count]}")
  end
end

def microsoft_dns_policy_bypass_ab(controller, config)
  dns = config['dns']
  fail_safely('effective config has no DNS mapping') unless dns.is_a?(Hash)
  nameservers = dns['nameserver']
  fail_safely('effective config has no main DNS list') unless nameservers.is_a?(Array) && !nameservers.empty?
  fallback = dns['fallback']
  fail_safely('effective config has no DNS fallback list') unless fallback.is_a?(Array) && !fallback.empty?
  fail_safely('effective config has no DNS fallback filter') unless dns['fallback-filter'].is_a?(Hash)
  existing_policy = dns['nameserver-policy']
  unless existing_policy.nil? || (existing_policy.is_a?(Hash) && existing_policy.empty?)
    fail_safely('DNS policy bypass A/B requires an empty nameserver-policy baseline')
  end

  initial_state = read_state(controller)
  fail_safely('DNS policy bypass A/B requires enabled mixed TUN') unless initial_state[:enable] && initial_state[:stack] == 'mixed'
  selections = selector_selections(controller)
  rule_targets = MICROSOFT_TUN_TEST_DOMAINS.map do |domain|
    resolve_simple_domain_rule(controller, domain)[:target]
  end.uniq
  fail_safely('Microsoft test domains do not share one rule target') unless rule_targets.length == 1
  microsoft_selector = rule_targets.first
  fail_safely('Microsoft rule target has no DIRECT member') unless selector_has_direct?(controller, microsoft_selector)

  variant = Marshal.load(Marshal.dump(config))
  variant['dns']['nameserver-policy'] = MICROSOFT_TUN_TEST_DOMAINS.each_with_object({}) do |domain, policy|
    policy[domain] = nameservers.dup
  end

  puts("baseline_fallback_count=#{fallback.length}")
  puts('baseline_fallback_filter_present=true')
  puts('baseline_nameserver_policy_count=0')
  puts("selector_snapshot_count=#{selections.length}")
  begin
    reload_config_payload(controller, variant)
    restored_variant_selectors = restore_selector_selections(controller, selections)
    sleep(2)
    variant_state = read_state(controller)
    fail_safely('DNS policy variant changed TUN enable') unless variant_state[:enable]
    fail_safely('DNS policy variant changed TUN stack') unless variant_state[:stack] == initial_state[:stack]
    fail_safely('DNS policy variant changed live inet6 state') unless variant_state[:inet6_count] == initial_state[:inet6_count]
    flush_dns_cache(controller)

    puts('variant=exact_domain_main_dns_policy')
    puts("variant_fallback_count=#{fallback.length}")
    puts('variant_fallback_filter_present=true')
    puts("variant_nameserver_policy_count=#{MICROSOFT_TUN_TEST_DOMAINS.length}")
    puts("variant_selector_restore_count=#{restored_variant_selectors}")
    puts("variant_tun_enable=#{variant_state[:enable]}")
    puts("variant_stack=#{variant_state[:stack]}")
    puts("variant_inet6_count=#{variant_state[:inet6_count]}")
    MICROSOFT_TUN_TEST_DOMAINS.each do |domain|
      dns_result = dns_query_summary(controller, domain, 'A')
      delay_result = proxy_delay_result(controller, 'DIRECT', domain)
      puts("variant_dns_domain=#{domain}")
      puts("variant_dns_result=#{dns_result[:result]}")
      puts("variant_dns_error_class=#{dns_result[:error_class]}")
      puts("variant_dns_answer_count=#{dns_result[:answer_count]}")
      puts("variant_dns_ipv4_count=#{dns_result[:ipv4_count]}")
      puts("variant_urltest_domain=#{domain}")
      puts("variant_urltest_result=#{delay_result[:result]}")
      puts("variant_delay_ms=#{delay_result[:delay_ms]}")
    end
    set_selector_sensitive(controller, microsoft_selector, 'DIRECT')
    puts('variant_microsoft_selector_direct=true')
    MICROSOFT_TUN_HTTP_TARGETS.each do |name, url|
      result = tun_http_probe(url)
      puts("functional_target=#{name}")
      puts("functional_outcome=#{result[:outcome]}")
      puts("functional_exit_code=#{result[:exit_code]}")
      puts("functional_http_code=#{result[:http_code]}")
      puts("functional_total_ms=#{result[:total_ms]}")
      puts("functional_tls_verify=#{result[:tls_verify]}")
    end
  ensure
    reload_config_payload(controller, config)
    restored_selectors = restore_selector_selections(controller, selections)
    sleep(2)
    restored_state = read_state(controller)
    flush_dns_cache(controller)
    puts("restored_selector_count=#{restored_selectors}")
    puts("restored_tun_enable=#{restored_state[:enable]}")
    puts("restored_stack=#{restored_state[:stack]}")
    puts("restored_inet6_present=#{restored_state[:inet6_present]}")
    puts("restored_inet6_count=#{restored_state[:inet6_count]}")
  end
end

def urltest_domain(controller, domain, mode, reference_domain)
  normalized_domain = normalize_public_domain(domain, 'urltest-domain')
  rule = nil
  target = case mode
           when 'direct'
             'DIRECT'
           when 'matched'
             rule = resolve_simple_domain_rule(controller, normalized_domain)
             rule[:target]
           when 'reference'
             normalized_reference = normalize_public_domain(reference_domain, 'urltest-domain reference')
             rule = resolve_simple_domain_rule(controller, normalized_reference)
             rule[:target]
           else
             fail_safely('urltest-domain mode must be direct, matched, or reference')
           end

  result = proxy_delay_result(controller, target, normalized_domain)
  puts("domain=#{normalized_domain}")
  puts("route_mode=#{mode}")
  puts("reference_domain=#{normalize_public_domain(reference_domain, 'urltest-domain reference')}") if mode == 'reference'
  puts("rule_type=#{rule ? rule[:type] : 'none'}")
  puts("rule_payload_fingerprint=#{rule ? rule[:payload_fingerprint] : 'none'}")
  puts("target_class=#{connection_route_class([target])}")
  puts("target_fingerprint=#{Digest::SHA256.hexdigest(target)[0, 16]}")
  puts("urltest_result=#{result[:result]}")
  puts("delay_ms=#{result[:delay_ms]}")
end

MICROSOFT_TUN_TEST_DOMAINS = [
  'www.microsoft.com',
  'login.live.com',
  'm365.cloud.microsoft'
].freeze

MICROSOFT_TUN_HTTP_TARGETS = {
  'microsoft_home' => 'https://www.microsoft.com/',
  'microsoft_account' => 'https://login.live.com/',
  'microsoft_365' => 'https://m365.cloud.microsoft/'
}.freeze

def patch_tun_stack(controller, stack)
  payload = { 'tun' => { 'enable' => true, 'stack' => stack } }
  status_code, = request(controller, method: 'PATCH', payload: payload)
  fail_safely('local controller TUN stack PATCH failed') unless status_code == 204

  state = read_state(controller)
  fail_safely('TUN was not enabled after stack PATCH') unless state[:enable]
  fail_safely('TUN stack verification failed') unless state[:stack] == stack
  state
end

def microsoft_stack_ab(controller)
  initial = read_state(controller)
  fail_safely('Microsoft stack A/B requires enabled TUN') unless initial[:enable]
  fail_safely('Microsoft stack A/B requires mixed baseline') unless initial[:stack] == 'mixed'

  puts('baseline_stack=mixed')
  puts("baseline_inet6_present=#{initial[:inet6_present]}")
  puts("baseline_inet6_count=#{initial[:inet6_count]}")
  begin
    ['system', 'gvisor'].each do |stack|
      state = patch_tun_stack(controller, stack)
      sleep(2)
      puts("variant_stack=#{stack}")
      puts("variant_tun_enable=#{state[:enable]}")
      puts("variant_inet6_present=#{state[:inet6_present]}")
      puts("variant_inet6_count=#{state[:inet6_count]}")
      MICROSOFT_TUN_TEST_DOMAINS.each do |domain|
        result = proxy_delay_result(controller, 'DIRECT', domain)
        puts("domain=#{domain}")
        puts("urltest_result=#{result[:result]}")
        puts("delay_ms=#{result[:delay_ms]}")
      end
    end
  ensure
    restored = patch_tun_stack(controller, initial[:stack])
    puts("restored_tun_enable=#{restored[:enable]}")
    puts("restored_stack=#{restored[:stack]}")
    puts("restored_inet6_present=#{restored[:inet6_present]}")
    puts("restored_inet6_count=#{restored[:inet6_count]}")
  end
end

def read_state(controller)
  status_code, body = request(controller, method: 'GET')
  fail_safely('local controller GET failed') unless status_code == 200

  config = JSON.parse(body)
  tun = config['tun']
  fail_safely('local controller response has no TUN state') unless tun.is_a?(Hash)

  inet6_address = tun['inet6-address']
  {
    enable: tun['enable'] == true,
    stack: tun['stack'].to_s.downcase,
    inet6_present: tun.key?('inet6-address'),
    inet6_kind: inet6_address.nil? ? 'none' : inet6_address.class.name.downcase,
    inet6_count: inet6_address.is_a?(Array) ? inet6_address.length : 0
  }
rescue JSON::ParserError
  fail_safely('local controller response is not valid JSON')
end

def print_state(controller, state)
  puts("controller_kind=#{controller[:kind]}")
  puts("controller_scope=#{controller[:scope]}")
  puts("controller_port_class=#{controller[:port_class]}")
  puts('controller_reachable=true')
  puts("tun_enable=#{state[:enable]}")
  puts("tun_stack=#{state[:stack]}")
  puts("tun_inet6_present=#{state[:inet6_present]}")
  puts("tun_inet6_kind=#{state[:inet6_kind]}")
  puts("tun_inet6_count=#{state[:inet6_count]}")
end

def require_watchdog_gate
  runtime_root = ENV['FLCLASH_PHASE1_WATCHDOG_RUNTIME_ROOT'].to_s
  fail_safely('TUN PATCH requires an armed Phase 1 network watchdog') if runtime_root.empty?

  verified_path = File.join(runtime_root, 'controller_verified')
  risk_path = File.join(runtime_root, 'risk_started')
  recovery_requested_path = File.join(runtime_root, 'recovery_requested')
  recovery_started_path = File.join(runtime_root, 'recovery_started')
  pid_path = File.join(runtime_root, 'watchdog.pid')
  verified = File.read(verified_path, mode: 'r:BOM|UTF-8').strip
  risk_started = File.read(risk_path, mode: 'r:BOM|UTF-8').strip
  recovery_requested = File.read(recovery_requested_path, mode: 'r:BOM|UTF-8').strip
  recovery_started = File.read(recovery_started_path, mode: 'r:BOM|UTF-8').strip
  watchdog_pid = Integer(File.read(pid_path, mode: 'r:BOM|UTF-8').strip, 10)
  recovery_lock = File.join(runtime_root, 'recovery.lock')
  recovery_mode = ENV['FLCLASH_PHASE1_WATCHDOG_RECOVERY'] == 'true'
  allowed = if recovery_mode
              verified == 'true' &&
                risk_started == 'true' &&
                recovery_requested == 'true' &&
                recovery_started == 'true' &&
                Dir.exist?(recovery_lock) &&
                Process.ppid == watchdog_pid
            else
              verified == 'true' &&
                risk_started == 'true' &&
                recovery_requested == 'false' &&
                recovery_started == 'false' &&
                !Dir.exist?(recovery_lock)
            end
  unless allowed
    fail_safely('TUN PATCH watchdog gate is not ready')
  end
  Process.kill(0, watchdog_pid)
rescue Errno::ENOENT, Errno::ESRCH, ArgumentError
  fail_safely('TUN PATCH watchdog process is unavailable')
end

command = ARGV.shift || 'snapshot'
if command == 'self-test-apple-filter'
  fail_safely('self-test-apple-filter accepts no arguments') unless ARGV.empty?
  self_test_apple_filter
  exit
end
if command == 'self-test-network-detection-filter'
  fail_safely('self-test-network-detection-filter accepts no arguments') unless ARGV.empty?
  self_test_network_detection_filter
  exit
end
require_watchdog_gate if command == 'set-tun'
config = load_effective_config
controller = controller_for(config)

case command
when 'snapshot'
  print_state(controller, read_state(controller))
when 'set-tun'
  enable_argument = ARGV.shift
  fail_safely('set-tun requires true or false') unless ['true', 'false'].include?(enable_argument)

  payload = { 'tun' => { 'enable' => enable_argument == 'true' } }
  unless ARGV.empty?
    fail_safely('expected --stack mixed|system|gvisor') unless ARGV.shift == '--stack'
    stack = ARGV.shift
    fail_safely('invalid TUN stack') unless ['mixed', 'system', 'gvisor'].include?(stack)
    fail_safely('unexpected extra arguments') unless ARGV.empty?
    payload['tun']['stack'] = stack
  end

  status_code, = request(controller, method: 'PATCH', payload: payload)
  fail_safely('local controller PATCH failed') unless status_code == 204

  state = read_state(controller)
  expected_enable = enable_argument == 'true'
  fail_safely('TUN enable verification failed') unless state[:enable] == expected_enable
  if payload['tun'].key?('stack') && state[:stack] != payload['tun']['stack']
    fail_safely('TUN stack verification failed')
  end
  print_state(controller, state)
when 'connections-domain'
  domain = ARGV.shift
  fail_safely('connections-domain requires exactly one domain') if domain.nil? || !ARGV.empty?
  trace_domain_connections(controller, domain)
when 'logs-domain'
  domain = ARGV.shift
  seconds = ARGV.shift || '10'
  fail_safely('logs-domain accepts DOMAIN and optional SECONDS') unless ARGV.empty?
  stream_domain_logs(controller, domain, seconds)
when 'logs-apple'
  seconds = ARGV.shift || '15'
  fail_safely('logs-apple accepts optional SECONDS') unless ARGV.empty?
  stream_apple_logs(controller, seconds)
when 'logs-network-detection'
  seconds = ARGV.shift || '30'
  fail_safely('logs-network-detection accepts optional SECONDS') unless ARGV.empty?
  stream_network_detection_logs(controller, seconds)
when 'urltest-domain'
  domain = ARGV.shift
  mode = ARGV.shift
  reference_domain = mode == 'reference' ? ARGV.shift : nil
  fail_safely('urltest-domain accepts DOMAIN MODE [REFERENCE_DOMAIN]') if domain.nil? || mode.nil? || !ARGV.empty?
  urltest_domain(controller, domain, mode, reference_domain)
when 'microsoft-stack-ab'
  fail_safely('microsoft-stack-ab accepts no arguments') unless ARGV.empty?
  microsoft_stack_ab(controller)
when 'rule-target-domain'
  domain = ARGV.shift
  fail_safely('rule-target-domain requires exactly one domain') if domain.nil? || !ARGV.empty?
  rule_target_summary(controller, domain)
when 'dns-domain'
  domain = ARGV.shift
  requested_type = ARGV.shift
  fail_safely('dns-domain accepts DOMAIN and optional A|AAAA|HTTPS') if domain.nil? || !ARGV.empty?
  dns_domain_summary(controller, domain, requested_type)
when 'flush-dns-cache'
  fail_safely('flush-dns-cache accepts no arguments') unless ARGV.empty?
  flush_dns_cache(controller)
when 'microsoft-dns-no-fallback-ab'
  fail_safely('microsoft-dns-no-fallback-ab accepts no arguments') unless ARGV.empty?
  microsoft_dns_no_fallback_ab(controller, config)
when 'microsoft-dns-policy-bypass-ab'
  fail_safely('microsoft-dns-policy-bypass-ab accepts no arguments') unless ARGV.empty?
  microsoft_dns_policy_bypass_ab(controller, config)
else
  fail_safely(
    'usage: macos_core_control.rb snapshot | connections-domain DOMAIN | logs-domain DOMAIN [SECONDS] | ' \
    'logs-apple [SECONDS] | self-test-apple-filter | ' \
    'logs-network-detection [SECONDS] | self-test-network-detection-filter | ' \
    'urltest-domain DOMAIN direct|matched|reference [REFERENCE_DOMAIN] | rule-target-domain DOMAIN | ' \
    'microsoft-stack-ab | ' \
    'dns-domain DOMAIN [A|AAAA|HTTPS] | ' \
    'flush-dns-cache | ' \
    'microsoft-dns-no-fallback-ab | ' \
    'microsoft-dns-policy-bypass-ab | ' \
    'set-tun true|false [--stack mixed|system|gvisor]'
  )
end
