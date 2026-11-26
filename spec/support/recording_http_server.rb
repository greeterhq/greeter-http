# frozen_string_literal: true

require 'webrick'

# A local HTTP server for specs that need to see the requests a tool really
# sends (mark-smoke-and-load-traffic-synthetic, design D4). It binds to
# 127.0.0.1 on a port the OS picks, records every request's method, path,
# headers and body, and answers each one through the block given to `new`:
#
#   server = RecordingHttpServer.new { |request| [201, '{"count":1}'] }
#   server.run do
#     # point the tool at server.base_url
#   end
#   server.requests # => [RecordingHttpServer::Request, ...]
#
# Header names are lowercased, so look them up as `headers['x-greeter-synthetic']`.
# WEBrick's access and error logs go to a null logger.
class RecordingHttpServer
  Request = Struct.new(:method, :path, :headers, :body, keyword_init: true)

  START_TIMEOUT_S = 5

  def initialize(&responder)
    raise ArgumentError, 'RecordingHttpServer needs a responder block' unless responder

    @responder = responder
    @requests = []
    @mutex = Mutex.new
  end

  def base_url
    raise 'RecordingHttpServer is not running' unless @server

    "http://127.0.0.1:#{@server.listeners.first.addr[1]}"
  end

  # A copy, so callers never see the array change under them.
  def requests
    @mutex.synchronize { @requests.dup }
  end

  # Starts the server, yields it, and shuts it down even if the block raises.
  def run
    start
    yield self
  ensure
    stop
  end

  private

  def start
    @server = WEBrick::HTTPServer.new(BindAddress: '127.0.0.1', Port: 0,
                                      Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    @server.mount_proc('/') { |req, res| handle(req, res) }
    @thread = Thread.new { @server.start }
    wait_until_running
  end

  def stop
    @server&.shutdown
    @thread&.join(START_TIMEOUT_S)
    @server = nil
    @thread = nil
  end

  def handle(req, res)
    request = Request.new(method: req.request_method, path: req.path,
                          headers: req.header.transform_values(&:first), body: req.body.to_s)
    @mutex.synchronize { @requests << request }
    status, body = @responder.call(request)
    res.status = status
    res['Content-Type'] = 'application/json'
    res.body = body.to_s
  end

  def wait_until_running
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + START_TIMEOUT_S
    until @server.status == :Running
      raise 'RecordingHttpServer did not start' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end
end
