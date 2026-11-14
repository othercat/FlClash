#!/usr/bin/env ruby

require 'socket'

HOST = '127.0.0.1'
CHUNK = "\0" * (64 * 1024)
CONTENT_LENGTH = 1 << 40

server = TCPServer.new(HOST, 0)
Signal.trap('INT') { exit }
Signal.trap('TERM') { exit }
STDOUT.sync = true
puts "server_scope=loopback"
puts "server_port=#{server.local_address.ip_port}"
puts 'server_ready=true'

loop do
  client = server.accept
  begin
    client.gets
    while (line = client.gets)
      break if line == "\r\n"
    end
    client.write(
      "HTTP/1.1 200 OK\r\n" \
      "Content-Type: application/octet-stream\r\n" \
      "Content-Length: #{CONTENT_LENGTH}\r\n" \
      "Connection: close\r\n\r\n",
    )
    loop { client.write(CHUNK) }
  rescue Errno::EPIPE, Errno::ECONNRESET
    # The rate-limited client intentionally disconnects after the capture.
  ensure
    client.close
  end
end
