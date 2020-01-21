require_relative '../helper'
require 'flexmock/test_unit'
require 'fluent/plugin_helper/http_server'
require 'fluent/plugin/output'
require 'fluent/event'
require 'net/http'
require 'uri'
require 'openssl'
require 'async'

class HtttpHelperTest < Test::Unit::TestCase
  PORT = unused_port
  NULL_LOGGER = Logger.new(nil)
  CERT_DIR = File.expand_path(File.dirname(__FILE__) + '/data/cert/without_ca')
  CERT_CA_DIR = File.expand_path(File.dirname(__FILE__) + '/data/cert/with_ca')

  class Dummy < Fluent::Plugin::TestBase
    helpers :http_server
  end

  def on_driver(config = nil)
    config ||= Fluent::Config.parse(config || '', '(name)', '')
    Fluent::Test.setup
    driver = Dummy.new
    driver.configure(config)
    driver.start
    driver.after_start

    yield(driver)
  ensure
    unless driver.stopped?
      driver.stop rescue nil
    end

    unless driver.before_shutdown?
      driver.before_shutdown rescue nil
    end

    unless driver.shutdown?
      driver.shutdown rescue nil
    end

    unless driver.after_shutdown?
      driver.after_shutdown rescue nil
    end

    unless driver.closed?
      driver.close rescue nil
    end

    unless driver.terminated?
      driver.terminated rescue nil
    end
  end

  def on_driver_transport(opts = {}, &block)
    transport_conf = config_element('transport', 'tls', opts)
    c = config_element('ROOT', '', {}, [transport_conf])
    on_driver(c, &block)
  end

  %w[get head].each do |n|
    define_method(n) do |uri, header = {}|
      url = URI.parse(uri)
      headers = { 'Content-Type' => 'application/x-www-form-urlencoded/' }.merge(header)
      req = Net::HTTP.const_get(n.capitalize).new(url, headers)
      Net::HTTP.start(url.host, url.port) do |http|
        http.request(req)
      end
    end

    define_method("secure_#{n}") do |uri, header = {}, verify: true, cert_path: nil, selfsigned: true, hostname: false|
      url = URI.parse(uri)
      headers = { 'Content-Type' => 'application/x-www-form-urlencoded/' }.merge(header)
      start_https_request(url.host, url.port, verify: verify, cert_path: cert_path, selfsigned: selfsigned) do |https|
        https.send(n, url.path, headers.to_a)
      end
    end
  end

  %w[post put patch delete options trace].each do |n|
    define_method(n) do |uri, body = '', header = {}|
      url = URI.parse(uri)
      headers = { 'Content-Type' => 'application/x-www-form-urlencoded/' }.merge(header)
      req = Net::HTTP.const_get(n.capitalize).new(url, headers)
      req.body = body
      Net::HTTP.start(url.host, url.port) do |http|
        http.request(req)
      end
    end
  end

  # wrapper for net/http
  Response = Struct.new(:code, :body, :headers)

  # Use async-http as http client since net/http can't be set verify_hostname= now
  # will be replaced when net/http supports verify_hostname=
  def start_https_request(addr, port, verify: true, cert_path: nil, selfsigned: true, hostname: nil)
    context = OpenSSL::SSL::SSLContext.new
    context.set_params({})
    if verify
      cert_store = OpenSSL::X509::Store.new
      cert_store.set_default_paths
      if selfsigned && OpenSSL::X509.const_defined?('V_FLAG_CHECK_SS_SIGNATURE')
        cert_store.flags = OpenSSL::X509::V_FLAG_CHECK_SS_SIGNATURE
      end

      if cert_path
        cert_store.add_file(cert_path)
      end

      context.cert_store = cert_store
      if !hostname && context.respond_to?(:verify_hostname=)
        context.verify_hostname = false # In test code, using hostname to be connected is very difficult
      end

      context.verify_mode = OpenSSL::SSL::VERIFY_PEER
    else
      context.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end

    client = Async::HTTP::Client.new(Async::HTTP::Endpoint.parse("https://#{addr}:#{port}", ssl_context: context))
    reactor = Async::Reactor.new(nil, logger: NULL_LOGGER)

    resp = nil
    error = nil

    reactor.run do
      begin
        response = yield(client)
      rescue => e               # Async::Reactor rescue all error. handle it by myself
        error = e
      end

      resp = Response.new(response.status.to_s, response.body.read, response.headers)
    end

    if error
      raise error
    else
      resp
    end
  end

  # def start_https_request(addr, port, verify: true, cert_path: nil, selfsigned: true)
  #   https = Net::HTTP.new(addr, port)
  #   https.use_ssl = true

  #   if verify
  #     cert_store = OpenSSL::X509::Store.new
  #     cert_store.set_default_paths
  #     if selfsigned && OpenSSL::X509.const_defined?('V_FLAG_CHECK_SS_SIGNATURE')
  #       cert_store.flags = OpenSSL::X509::V_FLAG_CHECK_SS_SIGNATURE
  #     end

  #     if cert_path
  #       cert_store.add_file(cert_path)
  #     end

  #     https.cert_store = cert_store

  #     # https.verify_hostname = false

  #     https.verify_mode = OpenSSL::SSL::VERIFY_PEER
  #   else
  #     https.verify_mode = OpenSSL::SSL::VERIFY_NONE
  #   end

  #   # if !hostname && context.respond_to?(:verify_hostname=)
  #   #   context.verify_hostname = false # In test code, using hostname to be connected is very difficult
  #   # end

  #   https.start do
  #     yield(https)
  #   end
  # end

  sub_test_case 'Create a HTTP server' do
    test 'monunt given path' do
      on_driver do |driver|
        driver.create_http_server(:http_server_helper_test, addr: '127.0.0.1', port: PORT, logger: NULL_LOGGER) do |s|
          s.get('/example/hello') { [200, { 'Content-Type' => 'text/plain' }, 'hello get'] }
          s.post('/example/hello') { [200, { 'Content-Type' => 'text/plain' }, 'hello post'] }
          s.head('/example/hello') { [200, { 'Content-Type' => 'text/plain' }, 'hello head'] }
          s.put('/example/hello') { [200, { 'Content-Type' => 'text/plain' }, 'hello put'] }
          s.patch('/example/hello') { [200, { 'Content-Type' => 'text/plain' }, 'hello patch'] }
          s.delete('/example/hello') { [200, { 'Content-Type' => 'text/plain' }, 'hello delete'] }
          s.trace('/example/hello') { [200, { 'Content-Type' => 'text/plain' }, 'hello trace'] }
          s.options('/example/hello') { [200, { 'Content-Type' => 'text/plain' }, 'hello options'] }
        end

        resp = head("http://127.0.0.1:#{PORT}/example/hello")
        assert_equal('200', resp.code)
        assert_equal(nil, resp.body)
        assert_equal('text/plain', resp['Content-Type'])

        %w[get put post put delete trace].each do |n|
          resp = send(n, "http://127.0.0.1:#{PORT}/example/hello")
          assert_equal('200', resp.code)
          assert_equal("hello #{n}", resp.body)
          assert_equal('text/plain', resp['Content-Type'])
        end

        # TODO: remove when fluentd drop ruby 2.1
        if Gem::Version.create(RUBY_VERSION) >= Gem::Version.create('2.2.0')
          resp = options("http://127.0.0.1:#{PORT}/example/hello")
          assert_equal('200', resp.code)
          assert_equal("hello options", resp.body)
          assert_equal('text/plain', resp['Content-Type'])
        end
      end
    end

    test 'when path does not start with `/` or ends with `/`' do
      on_driver do |driver|
        driver.create_http_server(:http_server_helper_test, addr: '127.0.0.1', port: PORT, logger: NULL_LOGGER) do |s|
          s.get('example/hello') { [200, { 'Content-Type' => 'text/plain' }, 'hello get'] }
          s.get('/example/hello2/') { [200, { 'Content-Type' => 'text/plain' }, 'hello get'] }
        end

        resp = get("http://127.0.0.1:#{PORT}/example/hello")
        assert_equal('404', resp.code)

        resp = get("http://127.0.0.1:#{PORT}/example/hello2")
        assert_equal('200', resp.code)
      end
    end

    test 'when error raised' do
      on_driver do |driver|
        driver.create_http_server(:http_server_helper_test, addr: '127.0.0.1', port: PORT, logger: NULL_LOGGER) do |s|
          s.get('/example/hello') { raise 'error!' }
        end

        resp = get("http://127.0.0.1:#{PORT}/example/hello")
        assert_equal('500', resp.code)
      end
    end

    test 'when path is not found' do
      on_driver do |driver|
        driver.create_http_server(:http_server_helper_test, addr: '127.0.0.1', port: PORT, logger: NULL_LOGGER) do |s|
          s.get('/example/hello') { [200, { 'Content-Type' => 'text/plain' }, 'hello get'] }
        end

        resp = get("http://127.0.0.1:#{PORT}/example/hello/not_found")
        assert_equal('404', resp.code)
      end
    end

    test 'params and body' do
      on_driver do |driver|
        driver.create_http_server(:http_server_helper_test, addr: '127.0.0.1', port: PORT, logger: NULL_LOGGER) do |s|
          s.get('/example/hello') do |req|
            assert_equal(req.query_string, nil)
            assert_equal(req.body, nil)
            [200, { 'Content-Type' => 'text/plain' }, 'hello get']
          end

          s.post('/example/hello') do |req|
            assert_equal(req.query_string, nil)
            assert_equal(req.body, 'this is body')
            [200, { 'Content-Type' => 'text/plain' }, 'hello post']
          end

          s.get('/example/hello/params') do |req|
            assert_equal(req.query_string, 'test=true')
            assert_equal(req.body, nil)
            [200, { 'Content-Type' => 'text/plain' }, 'hello get']
          end

          s.post('/example/hello/params') do |req|
            assert_equal(req.query_string, 'test=true')
            assert_equal(req.body, 'this is body')
            [200, { 'Content-Type' => 'text/plain' }, 'hello post']
          end
        end

        resp = get("http://127.0.0.1:#{PORT}/example/hello")
        assert_equal('200', resp.code)

        resp = post("http://127.0.0.1:#{PORT}/example/hello", 'this is body')
        assert_equal('200', resp.code)

        resp = get("http://127.0.0.1:#{PORT}/example/hello/params?test=true")
        assert_equal('200', resp.code)

        resp = post("http://127.0.0.1:#{PORT}/example/hello/params?test=true", 'this is body')
        assert_equal('200', resp.code)
      end
    end

    sub_test_case 'create a HTTPS server' do
      test '#configure' do
        driver = Dummy.new

        transport_conf = config_element('transport', 'tls', { 'version' => 'TLSv1_1' })
        driver.configure(config_element('ROOT', '', {}, [transport_conf]))
        assert_equal :tls, driver.transport_config.protocol
        assert_equal :TLSv1_1, driver.transport_config.version
      end

      sub_test_case '#http_server_create_https_server' do
        test 'can overwrite settings by using tls_context' do
          on_driver_transport({ 'insecure' => 'false' }) do |driver|
            tls = { 'insecure' => 'true' } # overwrite
            driver.http_server_create_https_server(:http_server_helper_test_tls, addr: '127.0.0.1', port: PORT, logger: NULL_LOGGER, tls_opts: tls) do |s|
              s.get('/example/hello') { [200, { 'Content-Type' => 'text/plain' }, 'hello get'] }
            end

            resp = secure_get("https://127.0.0.1:#{PORT}/example/hello", verify: false)
            assert_equal('200', resp.code)
            assert_equal('hello get', resp.body)
          end
        end

        test 'with insecure in transport section' do
          on_driver_transport({ 'insecure' => 'true' }) do |driver|
            driver.http_server_create_https_server(:http_server_helper_test_tls, addr: '127.0.0.1', port: PORT, logger: NULL_LOGGER) do |s|
              s.get('/example/hello') { [200, { 'Content-Type' => 'text/plain' }, 'hello get'] }
            end

            resp = secure_get("https://127.0.0.1:#{PORT}/example/hello", verify: false)
            assert_equal('200', resp.code)
            assert_equal('hello get', resp.body)

            assert_raise OpenSSL::SSL::SSLError do
              secure_get("https://127.0.0.1:#{PORT}/example/hello")
            end
          end
        end

        data(
          'with passphrase' => ['apple', 'cert-pass.pem', 'cert-key-pass.pem'],
          'without passphrase' => [nil, 'cert.pem', 'cert-key.pem'])
        test 'load self-signed cert/key pair, verified from clients using cert files' do |(passphrase, cert, private_key)|
          cert_path = File.join(CERT_DIR, cert)
          private_key_path = File.join(CERT_DIR, private_key)
          opt = { 'insecure' => 'false', 'private_key_path' => private_key_path, 'cert_path' => cert_path }
          if passphrase
            opt['private_key_passphrase'] = passphrase
          end

          on_driver_transport(opt) do |driver|
            driver.http_server_create_https_server(:http_server_helper_test_tls, addr: '127.0.0.1', port: PORT, logger: NULL_LOGGER) do |s|
              s.get('/example/hello') { [200, { 'Content-Type' => 'text/plain' }, 'hello get'] }
            end

            resp = secure_get("https://127.0.0.1:#{PORT}/example/hello", cert_path: cert_path)
            assert_equal('200', resp.code)
            assert_equal('hello get', resp.body)
          end
        end

        data(
          'with passphrase' => ['apple', 'cert-pass.pem', 'cert-key-pass.pem', 'ca-cert-pass.pem'],
          'without passphrase' => [nil, 'cert.pem', 'cert-key.pem', 'ca-cert.pem'])
        test 'load cert by private CA cert file, verified from clients using CA cert file' do |(passphrase, cert, cert_key, ca_cert)|
          cert_path = File.join(CERT_CA_DIR, cert)
          private_key_path = File.join(CERT_CA_DIR, cert_key)

          ca_cert_path = File.join(CERT_CA_DIR, ca_cert)

          opt = { 'insecure' => 'false', 'cert_path' => cert_path, 'private_key_path' => private_key_path }
          if passphrase
            opt['private_key_passphrase'] = passphrase
          end

          on_driver_transport(opt) do |driver|
            driver.http_server_create_https_server(:http_server_helper_test_tls, addr: '127.0.0.1', port: PORT, logger: NULL_LOGGER) do |s|
              s.get('/example/hello') { [200, { 'Content-Type' => 'text/plain' }, 'hello get'] }
            end

            resp = secure_get("https://127.0.0.1:#{PORT}/example/hello", cert_path: ca_cert_path)
            assert_equal('200', resp.code)
            assert_equal('hello get', resp.body)
          end
        end
      end
    end

    test 'must be called #start and #stop' do
      on_driver do |driver|
        server = flexmock('Server') do |watcher|
          watcher.should_receive(:start).once.and_return do |que|
            que.push(:start)
          end
          watcher.should_receive(:stop).once
        end

        stub(Fluent::PluginHelper::HttpServer::Server).new(anything) { server }
        driver.create_http_server(:http_server_helper_test, addr: '127.0.0.1', port: PORT, logger: NULL_LOGGER) do
          # nothing
        end
        driver.stop
      end
    end
  end
end
