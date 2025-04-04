#!/usr/bin/env ruby

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'logger'
  gem 'optparse'
end

require 'socket'
require 'logger'
require 'optparse'

logger = Logger.new(STDOUT)
logger.level = Logger::INFO

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: forward.rb [options]"

  opts.on("-p", "--ports PORTS", "A port or list of ports. Can be like: '8080', '8080:1234', or a comma-separated list") do |p|
    options[:ports] = p
  end

  opts.on("-c", "--container CONTAINER_ID", "The ID of the docker container") do |c|
    options[:container_id] = c
  end
end.parse!

if options[:ports].nil? || options[:ports].empty?
  raise "You must specify a port, or list of ports"
end

if options[:container_id].nil? || options[:container_id].empty?
  raise "You must specify a container id"
end

container_check_cmd = "docker inspect #{options[:container_id]} > /dev/null 2>&1"
unless system(container_check_cmd)
  logger.fatal("Error: Container '#{options[:container_id]}' does not exist or is not accessible")
  exit(1)
end

def check_socat_installed(container_id, logger)
  check_cmd = "docker exec #{container_id} which socat"
  result = system(check_cmd, out: File::NULL, err: File::NULL)

  unless result
    logger.error("Error: 'socat' is not installed in container #{container_id}")
    logger.error("Please install socat in the container with:")
    logger.error("  docker exec #{container_id} apt-get update && docker exec #{container_id} apt-get install -y socat")
    return false
  end

  return true
end

unless check_socat_installed(options[:container_id], logger)
  logger.fatal("Error: Cannot proceed without socat installed in the container")
  exit(1)
end

ports = []
options[:ports].split(',').each do |part|
  part = part.strip
  begin
    port = Integer(part)
    ports << port
  rescue ArgumentError
    logger.fatal("Failed to parse port #{part}")
    exit(1)
  end
end

def handle_connection(client, container_id, port, logger)
  logger.info("New connection received, forwarding to container #{container_id} port #{port}")

  unless check_socat_installed(container_id, logger)
    client.close
    return
  end

  cmd = "docker exec -i #{container_id} bash -c \"su - root -c 'socat - TCP:localhost:#{port}'\""
  io = IO.popen(cmd, 'r+b')  # Binary mode for better performance

  threads = []
  buffer_size = 16384  # 16KB buffer instead of 4KB
  threads << Thread.new do
    begin
      if client.respond_to?(:to_io) && io.respond_to?(:to_io)
        IO.copy_stream(client, io)
      else
        while (data = client.recv(buffer_size)) && !data.empty?
          io.write(data)
        end
      end
    rescue => e
      logger.error("Error in client->container thread: #{e.message}")
    ensure
      io.close_write rescue nil
    end
  end

  threads << Thread.new do
    begin
      if io.respond_to?(:to_io) && client.respond_to?(:to_io)
        IO.copy_stream(io, client)
      else
        while (data = io.read(buffer_size)) && !data.nil? && !data.empty?
          client.write(data)
        end
      end
    rescue => e
      logger.error("Error in container->client thread: #{e.message}")
    ensure
      client.close_write rescue nil
    end
  end

  threads.each(&:join)

  io.close rescue nil
  client.close rescue nil

  logger.info("Connection closed")
end

def configure_tcp_server(server)
  if server.respond_to?(:setsockopt)
    # Set TCP_NODELAY to disable Nagle's algorithm
    server.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
    server.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDBUF, 16384)
    server.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 16384)
    server.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true)
  end
end

def configure_client_socket(client)
  if client.respond_to?(:setsockopt)
    # Set TCP_NODELAY to disable Nagle's algorithm
    client.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)

    # Set socket buffer sizes
    client.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDBUF, 16384)
    client.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 16384)
  end
end

stop_signal = Queue.new
threads = []
max_threads = 20
thread_pool = Queue.new
max_threads.times { thread_pool << true }

ports.each do |port|
  threads << Thread.new do
    logger.info("Starting listener on port #{port}")

    begin
      server = TCPServer.new(port)
      configure_tcp_server(server)

      loop do
        client = server.accept
        _ = thread_pool.pop
        configure_client_socket(client)

        Thread.new do
          begin
            handle_connection(client, options[:container_id], port, logger)
          ensure
            thread_pool << true
          end
        end
      end
    rescue => e
      logger.error("Failed to listen on port #{port}: #{e.message}")
      stop_signal.push(true)
    end
  end
end

Signal.trap("INT") do
  logger.info("Received interrupt signal, shutting down...")
  stop_signal.push(true) unless stop_signal.closed?
end

Signal.trap("TERM") do
  logger.info("Received termination signal, shutting down...")
  stop_signal.push(true) unless stop_signal.closed?
end

begin
  stop_signal.pop
  logger.info("Shutting down...")
rescue ThreadError
  # Queue might be closed already
end
