module Rack
  class Prerender
    require 'net/http'

    DISALLOWED_PHANTOMJS_HEADERS = %w(
      cache-control
      content-length
      transfer-encoding
      connection
      date
    )

    def initialize(app, options={})
      # googlebot, yahoo, and bingbot are in this list even though
      # we support _escaped_fragment_ to ensure it works for people
      # who might not use the _escaped_fragment_ protocol
      @crawler_user_agents = [
        'googlebot',
        'yahoo',
        'bingbot',
        'baiduspider',
        'facebookexternalhit',
        'twitterbot',
        'adsbot-google',
        'mediapartners-google',
        'outbrain',     # Outbrain needs to see prerender
        'http_request2',# From pocket reader?
        'digg',
        'pubexchange',
        'socialflow'
      ]

      @extensions_to_ignore = [
        '.js',
        '.css',
        '.xml',
        '.less',
        '.png',
        '.jpg',
        '.jpeg',
        '.gif',
        '.pdf',
        '.doc',
        '.txt',
        '.zip',
        '.mp3',
        '.rar',
        '.exe',
        '.wmv',
        '.doc',
        '.avi',
        '.ppt',
        '.mpg',
        '.mpeg',
        '.tif',
        '.wav',
        '.mov',
        '.psd',
        '.ai',
        '.xls',
        '.mp4',
        '.m4a',
        '.swf',
        '.dat',
        '.dmg',
        '.iso',
        '.flv',
        '.m4v',
        '.torrent'
      ]

      @options = options
      @options[:whitelist]      = [@options[:whitelist]] if @options[:whitelist].is_a? String
      @options[:blacklist]      = [@options[:blacklist]] if @options[:blacklist].is_a? String
      @app = app
    end

    def call(env)
      if should_show_prerendered_page(env)
        # the before_render callback can return a string of HTML that
        # gets converted to a rack response
        cached_response = before_render(env)

        if cached_response && cached_response.is_a?(Rack::Response)
          return cached_response.finish
        end

        prerendered_response = get_prerendered_page_response(env)

        if prerendered_response
          response = build_rack_response_from_prerender(prerendered_response)
          after_render(env, prerendered_response)
          return response.finish
        end
      end

      @app.call(env)  
    end

    def should_show_prerendered_page(env)
      user_agent = env['HTTP_USER_AGENT']
      return false if !user_agent
      return false if env['REQUEST_METHOD'] != 'GET'

      request = Rack::Request.new(env)

      #if it is a bot and not requesting a resource and is not blacklisted(url or referer)...dont prerender
      if @options[:blacklist].is_a?(Array) && @options[:blacklist].any? { |blacklisted|
          blacklistedUrl = false
          blacklistedReferer = false
          regex = Regexp.new(blacklisted)

          blacklistedUrl = !!regex.match(request.path)
          blacklistedReferer = !!regex.match(request.referer) if request.referer

          blacklistedUrl || blacklistedReferer
        }
        return false
      end 

      return true if Rack::Utils.parse_query(request.query_string).has_key?('_escaped_fragment_')

      #if it is not a bot...dont prerender
      return false if @crawler_user_agents.all? { |crawler_user_agent| !user_agent.downcase.include?(crawler_user_agent.downcase) }

      #if it is a bot and is requesting a resource...dont prerender
      return false if @extensions_to_ignore.any? { |extension| request.path.include? extension }

      #if it is a bot and not requesting a resource and is not whitelisted...dont prerender
      return false if @options[:whitelist].is_a?(Array) && @options[:whitelist].all? { |whitelisted| !Regexp.new(whitelisted).match(request.path) }

      return true
    end

    def get_prerendered_page_response(env)
      begin
        request = Rack::Request.new(env)
        prerender_url = URI.parse(build_api_url(env))

        headers = { 'User-Agent' => env['HTTP_USER_AGENT'] }
        headers['X-Prerender-Token'] = ENV['PRERENDER_TOKEN'] if ENV['PRERENDER_TOKEN']

        req = Net::HTTP::Get.new(prerender_url.request_uri, headers)
        http = Net::HTTP.new(prerender_url.host, prerender_url.port)

        http.use_ssl = true if prerender_with_fastboot?(request)
        Rails.logger.info "*** Prerendering with #{prerender_url}"
        response = http.start { |http| http.request(req) }
      rescue
        nil
      end
    end

    def build_api_url(env)
      request = Rack::Request.new(env)
      if prerender_with_fastboot?(request)
        fastboot_uri = URI(ENV['FASTBOOT_URL'])
        fastboot_uri.query = "path=#{request.path}"
        fastboot_uri.to_s
      else
        prerender_url = get_prerender_service_url()
        forward_slash = prerender_url[-1, 1] == '/' ? '' : '/'
        "#{prerender_url}#{forward_slash}#{request.url}"
      end
    end

    def get_prerender_service_url
      @options[:prerender_service_url] || ENV['PRERENDER_SERVICE_URL'] || 'http://prerender.herokuapp.com/'
    end

    def build_rack_response_from_prerender(prerendered_response)
      response = Rack::Response.new

      # Pass through only applicable 
      prerendered_response.each do |name, val|
        next if DISALLOWED_PHANTOMJS_HEADERS.include? name
        response[name] = val
      end

      # Set response status and content body
      response.status = prerendered_response.code
      response.write prerendered_response.body
      response
    end

    def before_render(env)
      return nil unless @options[:before_render]
      
      cached_render = @options[:before_render].call(env)
      
      if cached_render && cached_render.is_a?(String)
        response = Rack::Response.new(cached_render, 200, [])
        response['Content-Type'] = 'text/html'
        response
      else
        nil
      end
    end

    def after_render(env, response)
      return true unless @options[:after_render]
      @options[:after_render].call(env, response)
    end

    private

    def prerender_with_fastboot?(request)
      return false unless @options[:fastboot_whitelist].is_a?(Array)

      @options[:fastboot_whitelist].any?{ |regex| request.path =~ regex }
    end
  end
end
