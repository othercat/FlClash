#!/usr/bin/ruby

require 'digest'
require 'json'
require 'open3'
require 'time'

def fail_safely(message)
  warn(message)
  exit(1)
end

def classify_subsystem(value)
  case value.to_s
  when 'com.apple.apsd'
    'apsd'
  when 'com.apple.PersistentConnection'
    'persistent_connection'
  when 'com.apple.network'
    'network'
  when 'com.apple.securityd'
    'security'
  when 'com.apple.xpc'
    'xpc'
  when ''
    'none'
  else
    'other'
  end
end

def classify_category(value)
  normalized = value.to_s.downcase
  return 'sandbox_push' if normalized.include?('sandbox.push.apple.com')
  return 'production_push' if normalized.include?('push.apple.com')
  return 'courier' if normalized.include?('courier')
  return 'connection' if normalized.include?('connection')
  return 'stream' if normalized.include?('stream')
  return 'timer' if normalized.include?('timer')
  return 'tls' if normalized.include?('boringssl') || normalized.include?('tls')
  return 'xpc' if normalized.include?('xpc')
  return 'security' if normalized.include?('security') || normalized.include?('seccritical')
  return 'none' if normalized.empty?

  'other'
end

def classify_host(value)
  normalized = value.to_s.downcase
  return 'sandbox_push' if normalized.include?('sandbox.push.apple.com')
  return 'courier_push' if normalized.match?(/(?:\A|[.\s-])courier\.push\.apple\.com/)
  return 'production_push' if normalized.include?('push.apple.com')

  'none'
end

def classify_family(value)
  normalized = value.to_s.downcase
  has_ipv4 = normalized.include?('ipv4')
  has_ipv6 = normalized.include?('ipv6')
  return 'dual' if has_ipv4 && has_ipv6
  return 'ipv4' if has_ipv4
  return 'ipv6' if has_ipv6

  'unspecified'
end

def classify_port(value)
  normalized = value.to_s
  return 'apns_5223' if normalized.match?(/(?:\A|\D)5223(?:\D|\z)/)
  return 'https_443' if normalized.match?(/(?:\A|\D)443(?:\D|\z)/)

  'unspecified'
end

def classify_error(value)
  normalized = value.to_s.downcase
  return 'timeout' if normalized.include?('timeout') || normalized.include?('timed out')
  return 'refused' if normalized.include?('refused')
  return 'reset' if normalized.include?('reset')
  return 'unreachable' if normalized.include?('unreachable') || normalized.include?('no route')
  return 'tls' if normalized.include?('tls') || normalized.include?('ssl') || normalized.include?('handshake')
  return 'dns' if normalized.include?('dns') || normalized.include?('resolve') || normalized.include?('lookup')
  return 'canceled' if normalized.include?('cancel')
  return 'generic' if normalized.include?('error') || normalized.include?('fail')

  'none'
end

def classify_operation(value)
  normalized = value.to_s.downcase
  return 'connection_down' if normalized.match?(/disconnected|connection (?:is )?closed|close connection|lost connection/)
  return 'connection_up' if normalized.match?(/connection established|connection is connected|connected to|became connected/)
  return 'tls_handshake' if normalized.include?('handshake') || normalized.include?('boringssl')
  return 'connect_attempt' if normalized.match?(/connect|connection/)
  return 'retry' if normalized.match?(/retry|reconnect|backoff/)
  return 'keepalive' if normalized.match?(/keepalive|keep-alive|heartbeat/)
  return 'network_change' if normalized.match?(/network.*chang|path.*chang|interface.*chang/)
  return 'timer' if normalized.include?('timer')
  return 'stream' if normalized.include?('stream')
  return 'message' if normalized.match?(/message|notification|push/)

  'other'
end

def network_event_kind(format)
  normalized = format.to_s.downcase
  return 'socket_connected' if normalized.include?('socket received connected event')
  return 'socket_disconnected' if normalized.include?('socket received disconnected event')
  return 'socket_error' if normalized.include?('socket so_error')
  return 'protocol_connected' if normalized.include?('protocol connected')
  return 'tls_configured' if normalized.include?('tls configured')
  return 'tls_lower_stack_error' if normalized.include?('lower protocol stack error during tls handshake')
  return 'courier_config' if normalized.include?('connecting courier stream using configuration bag')
  return 'courier_connect' if normalized.include?('connecting to courier')
  return 'stream_open' if normalized.include?('opening stream')
  return 'stream_error' if normalized.include?('stream error occurred')
  return 'stream_disconnect' if normalized.include?('_disconnectstream')
  return 'connection_failure' if normalized.include?('disconnected in response to connection failure')
  return 'connection_closed' if normalized.include?('connection closed')
  return 'connected_flag' if normalized.include?('setting is connected')
  return 'connect_attempt' if normalized.include?('attempting to _connectstream')
  return 'connect_dispatch' if normalized.include?('calling _connectstream')
  return 'connection_manager_stop' if normalized.include?('stopping the connectionmanager')
  return 'network_error_event' if normalized.match?(/\bevent:.*error/)
  return 'network_state' if normalized.include?('reporting state')
  return 'retry_scheduled' if normalized.match?(/scheduling retry|reconnect timer/)

  nil
end

def connected_value(message)
  match = message.to_s.match(/setting is connected\s+(true|false|yes|no|1|0)/i)
  return 'true' if match && ['true', 'yes', '1'].include?(match[1].downcase)
  return 'false' if match

  'unknown'
end

def sanitized_template(value)
  result = value.to_s.dup
  result.gsub!(/[\r\n]+/, ' ')
  result.gsub!(/%\{[^}]+\}[-+0-9.*]*[A-Za-z@]/, '<arg>')
  result.gsub!(/%[-+0-9.*]*[A-Za-z@]/, '<arg>')
  result.gsub!(/\b[A-Fa-f0-9]{8}-[A-Fa-f0-9-]{27,}\b/, '<id>')
  result.gsub!(/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/, '<email>')
  result.gsub!(/\b(?:\d{1,3}\.){3}\d{1,3}\b/, '<ip>')
  result.gsub!(%r{/(?:Users|private|var|tmp|Volumes)/\S+}, '<path>')
  result.gsub!(/\b[A-Fa-f0-9]{16,}\b/, '<id>')
  result.gsub!(/\b[A-Za-z0-9_-]{24,}\b/, '<id>')
  result.gsub!(/\b(?!(?:[A-Za-z0-9-]+\.)*(?:apple\.com)\b)(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}\b/i, '<domain>')
  result.gsub!(/\d+/, '<n>')
  result.gsub!(/\s+/, ' ')
  result.strip[0, 240]
end

def load_rows(seconds)
  output, _error, status = Open3.capture3(
    '/usr/bin/log',
    'show',
    '--last',
    "#{seconds}s",
    '--style',
    'json',
    '--predicate',
    'process == "apsd"'
  )
  fail_safely('apsd unified-log query failed') unless status.success?

  rows = JSON.parse(output)
  fail_safely('apsd unified-log root is not an array') unless rows.is_a?(Array)
  rows.select { |row| row.is_a?(Hash) }
rescue JSON::ParserError
  fail_safely('apsd unified-log output is not valid JSON')
end

def print_summary(rows, seconds)
  summaries = rows.each_with_object(Hash.new(0)) do |row, counts|
    source = "#{row['formatString']} #{row['eventMessage']}"
    key = [
      classify_subsystem(row['subsystem']),
      classify_category(row['category']),
      row['messageType'].to_s.downcase.empty? ? 'none' : row['messageType'].to_s.downcase,
      classify_operation(source),
      classify_error(source),
      classify_host(source),
      classify_family(source),
      classify_port(source)
    ]
    counts[key] += 1
  end

  puts("window_seconds=#{seconds}")
  puts("apsd_events=#{rows.length}")
  puts("summary_rows=#{summaries.length}")
  summaries.sort_by { |key, count| [-count, key] }.each_with_index do |(key, count), index|
    prefix = "summary_#{index + 1}"
    puts("#{prefix}_count=#{count}")
    puts("#{prefix}_subsystem=#{key[0]}")
    puts("#{prefix}_category=#{key[1]}")
    puts("#{prefix}_message_type=#{key[2]}")
    puts("#{prefix}_operation=#{key[3]}")
    puts("#{prefix}_error_class=#{key[4]}")
    puts("#{prefix}_host_class=#{key[5]}")
    puts("#{prefix}_family=#{key[6]}")
    puts("#{prefix}_port_class=#{key[7]}")
  end
end

def print_templates(rows, seconds)
  templates = rows.map do |row|
    template = sanitized_template(row['formatString'])
    next if template.empty?

    normalized = template.downcase
    next unless normalized.match?(/connect|courier|push|network|stream|timer|tls|ssl|error|fail|retry/)

    template
  end.compact
  counts = templates.each_with_object(Hash.new(0)) { |template, result| result[template] += 1 }

  puts("window_seconds=#{seconds}")
  puts("template_rows=#{counts.length}")
  counts.sort_by { |template, count| [-count, template] }.first(80).each_with_index do |(template, count), index|
    prefix = "template_#{index + 1}"
    puts("#{prefix}_count=#{count}")
    puts("#{prefix}_fingerprint=#{Digest::SHA256.hexdigest(template)[0, 16]}")
    puts("#{prefix}_text=#{template}")
  end
end

def print_network_timeline(rows, seconds)
  selected = rows.map do |row|
    kind = network_event_kind(row['formatString'])
    next unless kind

    timestamp = Time.iso8601(row['timestamp'].to_s)
    source = "#{row['formatString']} #{row['eventMessage']}"
    {
      timestamp: timestamp,
      kind: kind,
      message_type: row['messageType'].to_s.downcase.empty? ? 'none' : row['messageType'].to_s.downcase,
      host_class: classify_host(source),
      family: classify_family(source),
      port_class: classify_port(source),
      error_class: classify_error(source),
      connected_value: connected_value(row['eventMessage'])
    }
  rescue ArgumentError
    next
  end.compact.sort_by { |event| event[:timestamp] }

  first_timestamp = selected.first&.fetch(:timestamp)
  puts("window_seconds=#{seconds}")
  puts("timeline_events=#{selected.length}")
  selected.first(240).each_with_index do |event, index|
    prefix = "event_#{index + 1}"
    offset_ms = ((event[:timestamp] - first_timestamp) * 1000).round
    puts("#{prefix}_offset_ms=#{offset_ms}")
    puts("#{prefix}_kind=#{event[:kind]}")
    puts("#{prefix}_message_type=#{event[:message_type]}")
    puts("#{prefix}_host_class=#{event[:host_class]}")
    puts("#{prefix}_family=#{event[:family]}")
    puts("#{prefix}_port_class=#{event[:port_class]}")
    puts("#{prefix}_error_class=#{event[:error_class]}")
    puts("#{prefix}_connected_value=#{event[:connected_value]}")
  end
  puts("timeline_truncated=#{selected.length > 240}")
end

def self_test
  dangerous = 'user@example.com 192.168.1.4 /Users/private/name 123e4567-e89b-12d3-a456-426614174000 abcdef0123456789abcdef0123456789 example.org 5223'
  sanitized = sanitized_template(dangerous)
  forbidden = ['user@example.com', '192.168.1.4', '/Users/private/name', '123e4567', 'abcdef0123456789', 'example.org']
  fail_safely('apsd sanitizer self-test failed') if forbidden.any? { |value| sanitized.include?(value) }
  fail_safely('apsd classifier self-test failed') unless classify_port(dangerous) == 'apns_5223'
  fail_safely('apsd classifier self-test failed') unless classify_host('courier.push.apple.com') == 'courier_push'

  fail_safely('apsd network-event self-test failed') unless network_event_kind('Socket received CONNECTED event') == 'socket_connected'
  fail_safely('apsd connected-value self-test failed') unless connected_value('Setting is connected YES on interface') == 'true'

  puts('self_test_cases=5')
  puts('self_test_passed=true')
end

command = ARGV.shift || 'summary'
if command == 'self-test'
  fail_safely('self-test accepts no arguments') unless ARGV.empty?
  self_test
  exit
end

seconds = ARGV.shift || '30'
fail_safely('seconds must be between 1 and 300') unless seconds.match?(/\A\d+\z/) && seconds.to_i.between?(1, 300)
fail_safely('unexpected extra arguments') unless ARGV.empty?
rows = load_rows(seconds.to_i)

case command
when 'summary'
  print_summary(rows, seconds.to_i)
when 'templates'
  print_templates(rows, seconds.to_i)
when 'timeline'
  print_network_timeline(rows, seconds.to_i)
else
  fail_safely('usage: macos_apsd_log_capture.rb summary|templates|timeline [SECONDS] | self-test')
end
