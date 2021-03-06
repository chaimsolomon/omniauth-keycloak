require 'omniauth'
require 'omniauth-oauth2'
require 'json/jwt'

module OmniAuth
    module Strategies
        class KeycloakOpenId < OmniAuth::Strategies::OAuth2
            attr_reader :authorize_url
            attr_reader :token_url
            attr_reader :cert

            def initialize(app, *args, &block)
                original_initialize_return_value = super
                # Do the setup at app start, not only at the first request
                setup_phase if ENV['KC_ACTIVE'] == 'true'
                original_initialize_return_value
            end

            def call(env)
                setup_phase if ENV['KC_ACTIVE'] == 'true'
                # Add the end_session_endpoint to the environment of the request
                env['end_session_endpoint'] = @end_session_endpoint
                super
            end

            def authorize_params
                if request.cookies['kc_state']
                    options.authorize_params[:state] =  request.cookies['kc_state']
                else
                    options.authorize_params[:state] = SecureRandom.hex(24)
                end
                params = options.authorize_params.merge(options_for("authorize"))
                if OmniAuth.config.test_mode
                    @env ||= {}
                    @env["rack.session"] ||= {}
                end
                session["omniauth.state"] = params[:state]
                req = Rack::Request.new(env)
                if req.cookies['kc_idp_hint']
                    params['kc_idp_hint'] = req.cookies['kc_idp_hint']
                end
                params
            end

            def setup_phase
                if @authorize_url.nil? || @token_url.nil?
                    realm = options.client_options[:realm].nil? ? options.client_id : options.client_options[:realm]
                    site = options.client_options[:site]
                    response = Faraday.get "#{options.client_options[:site]}/auth/realms/#{realm}/.well-known/openid-configuration"
                    if (response.status == 200)
                        json = MultiJson.load(response.body)
                        puts json
                        @certs_endpoint = json["jwks_uri"]
                        @userinfo_endpoint = json["userinfo_endpoint"]
                        @authorize_url = json["authorization_endpoint"].gsub(site, "")
                        @token_url = json["token_endpoint"].gsub(site, "")
                        # Keep the end_session_endpoint available
                        @end_session_endpoint = json["end_session_endpoint"]
                        options.client_options.merge!({
                            authorize_url: @authorize_url,
                            token_url: @token_url
                        })
                        certs = Faraday.get @certs_endpoint
                        if (certs.status == 200)
                            json = MultiJson.load(certs.body)
                            @cert = json["keys"][0]
                        else
                            #TODO: Throw Error
                            puts "Couldn't get Cert"
                        end
                    else
                        #TODO: Throw Error
                        puts response.status
                    end
                end
            end

            def build_access_token
                verifier = request.params["code"]
                client.auth_code.get_token(verifier,
                    {:redirect_uri => callback_url.gsub(/\?.+\Z/, "")}
                    .merge(token_params.to_hash(:symbolize_keys => true)),
                    deep_symbolize(options.auth_token_params))
            end

            uid{ raw_info['sub'] }

            info do
            {
                :name => raw_info['name'],
                :email => raw_info['email'],
                :first_name => raw_info['given_name'],
                :last_name => raw_info['family_name']
            }
            end

            extra do
            {
                'raw_info' => raw_info
            }
            end

            def raw_info
                id_token_string = access_token.token
                jwk = JSON::JWK.new(@cert)
                id_token = JSON::JWT.decode id_token_string, jwk
                id_token
            end

            OmniAuth.config.add_camelization('keycloak_openid', 'KeycloakOpenId')
        end
    end
end