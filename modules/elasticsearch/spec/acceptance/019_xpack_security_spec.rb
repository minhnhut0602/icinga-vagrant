require 'spec_helper_acceptance'
require 'json'

describe 'elasticsearch x-pack security',
         :if => is_5x_capable?,
         :with_certificates => true,
         :then_purge => true do
  # Template manifest
  let :base_manifest do
    <<-EOF
      class { 'elasticsearch' :
        java_install => true,
        #{fact('operatingsystemmajrelease') == '6' ? "java_package => 'java-1.8.0-openjdk-headless'," : ''}
        manage_repo  => true,
        repo_version => '#{test_settings['repo_version5x']}',
        config => {
          'cluster.name' => '#{test_settings['cluster_name']}',
          'http.port' => #{test_settings['port_a']},
          'network.host' => '0.0.0.0',
        },
        restart_on_change => true,
        security_plugin => 'x-pack',
        jvm_options => [
          '-Xms256m',
          '-Xmx256m',
        ],
      }

      elasticsearch::plugin { 'x-pack' :  }
    EOF
  end

  describe 'user authentication' do
    describe 'single instance manifest' do
      let :single_manifest do
        base_manifest + <<-EOF
          elasticsearch::instance { ['es-01'] :  }

          Elasticsearch::Plugin { instances => ['es-01'],  }

          elasticsearch::user { '#{test_settings['security_user']}':
            password => '#{test_settings['security_password']}',
            roles    => ['superuser'],
          }
          elasticsearch::user { '#{test_settings['security_user']}pwchange':
            password => '#{test_settings['security_hashed_password']}',
            roles    => ['superuser'],
          }
        EOF
      end

      it 'should apply cleanly' do
        apply_manifest single_manifest, :catch_failures => true
      end

      it 'should be idempotent' do
        apply_manifest(
          single_manifest,
          :catch_changes => true
        )
      end
    end

    describe port(test_settings['port_a']) do
      it 'open', :with_retries do
        should be_listening
      end
    end

    describe server :container do
      describe http(
        "http://localhost:#{test_settings['port_a']}/_cluster/health"
      ) do
        it 'denies unauthorized access', :with_retries do
          expect(response.status).to eq(401)
        end
      end

      describe http(
        "http://localhost:#{test_settings['port_a']}/_cluster/health",
        :basic_auth => [
          test_settings['security_user'],
          test_settings['security_password']
        ]
      ) do
        it 'permits authorized access', :with_retries do
          expect(response.status).to eq(200)
        end
      end

      describe http(
        "http://localhost:#{test_settings['port_a']}/_cluster/health",
        :basic_auth => [
          "#{test_settings['security_user']}pwchange",
          test_settings['security_hashed_plaintext']
        ]
      ) do
        it 'permits authorized access using pre-hashed creds',
           :with_retries do
          expect(response.status).to eq(200)
        end
      end
    end
  end

  describe 'changing passwords' do
    describe 'password change manifest' do
      let :passwd_manifest do
        base_manifest + <<-EOF
          elasticsearch::instance { ['es-01'] :  }

          Elasticsearch::Plugin { instances => ['es-01'],  }

          notify { 'change password' : } ~>
          elasticsearch::user { '#{test_settings['security_user']}pwchange':
            password => '#{test_settings['security_password'][0..5]}',
            roles    => ['superuser'],
          }
        EOF
      end

      it 'should apply cleanly' do
        apply_manifest passwd_manifest, :catch_failures => true
      end
    end

    describe port(test_settings['port_a']) do
      it 'open', :with_retries do
        should be_listening
      end
    end

    describe server :container do
      describe http(
        "http://localhost:#{test_settings['port_a']}/_cluster/health",
        :basic_auth => [
          "#{test_settings['security_user']}pwchange",
          test_settings['security_password'][0..5]
        ]
      ) do
        it 'authorizes changed passwords', :with_retries do
          expect(response.status).to eq(200)
        end
      end
    end
  end

  describe 'role permission control' do
    describe 'single instance manifest' do
      let :single_manifest do
        base_manifest + <<-EOF
          elasticsearch::instance { ['es-01'] :  }

          Elasticsearch::Plugin { instances => ['es-01'],  }

          elasticsearch::role { '#{@role}':
            privileges => {
              'cluster' => [
                'cluster:monitor/health',
              ],
              'indices' => [{
                'names'      => [ '#{test_settings['index']}' ],
                'privileges' => [ 'create_index', 'delete_index' ],
              }]
            }
          }

          elasticsearch::user { '#{test_settings['security_user']}':
            password => '#{test_settings['security_password']}',
            roles    => ['#{@role}'],
          }
        EOF
      end

      it 'should apply cleanly' do
        apply_manifest single_manifest, :catch_failures => true
      end

      it 'should be idempotent' do
        apply_manifest(
          single_manifest,
          :catch_changes => true
        )
      end
    end

    describe port(test_settings['port_a']) do
      it 'open', :with_retries do
        should be_listening
      end
    end

    # Cluster API denial
    describe server :container do
      describe http(
        "http://localhost:#{test_settings['port_a']}/_cluster/stats",
        :basic_auth => [
          test_settings['security_user'],
          test_settings['security_password']
        ]
      ) do
        it 'denies stats API access', :with_retries do
          expect(response.status).to eq(403)
        end
      end

      # Cluser API permitted
      describe http(
        "http://localhost:#{test_settings['port_a']}/_cluster/health",
        :basic_auth => [
          test_settings['security_user'],
          test_settings['security_password']
        ]
      ) do
        it 'permits health API access', :with_retries do
          expect(response.status).to eq(200)
        end
      end

      # Index creation permission
      describe http(
        "http://localhost:#{test_settings['port_a']}/#{test_settings['index']}",
        :basic_auth => [
          test_settings['security_user'],
          test_settings['security_password']
        ],
        :method => :put
      ) do
        it 'permits index creation', :with_retries do
          expect(response.status).to eq(200)
        end
      end

      # Document indexing denial
      describe http(
        "http://localhost:#{test_settings['port_a']}/#{test_settings['index']}/a/b",
        :basic_auth => [
          test_settings['security_user'],
          test_settings['security_password']
        ],
        :method => :put,
        :body => '{ "foo" => "bar" }'
      ) do
        it 'denies indexing', :with_retries do
          expect(response.status).to eq(403)
        end
      end

      # Index deletion permission
      describe http(
        "http://localhost:#{test_settings['port_a']}/#{test_settings['index']}",
        :basic_auth => [
          test_settings['security_user'],
          test_settings['security_password']
        ],
        :method => :delete
      ) do
        it 'denies indexing', :with_retries do
          expect(response.status).to eq(200)
        end
      end
    end
  end

  describe 'tls' do
    describe 'single instance' do
      describe 'manifest' do
        let :single_manifest do
          base_manifest + <<-EOF
            elasticsearch::instance { 'es-01':
              ssl                  => true,
              ca_certificate       => '#{@tls[:ca][:cert][:path]}',
              certificate          => '#{@tls[:clients].first[:cert][:path]}',
              private_key          => '#{@tls[:clients].first[:key][:path]}',
              keystore_password    => '#{@keystore_password}',
            }

            Elasticsearch::Plugin { instances => ['es-01'],  }

            elasticsearch::user { '#{test_settings['security_user']}':
              password => '#{test_settings['security_password']}',
              roles => ['superuser'],
            }
          EOF
        end

        it 'should apply cleanly' do
          apply_manifest single_manifest, :catch_failures => true
        end

        it 'should be idempotent' do
          apply_manifest(
            single_manifest,
            :catch_changes => true
          )
        end
      end

      describe port(test_settings['port_a']) do
        it 'open', :with_retries do
          should be_listening
        end
      end

      describe server :container do
        describe http(
          "https://localhost:#{test_settings['port_a']}/_cluster/health",
          :basic_auth => [
            test_settings['security_user'],
            test_settings['security_password']
          ],
          :ssl => { :verify => false }
        ) do
          it 'permits TLS health API access', :with_retries do
            expect(response.status).to eq(200)
          end
        end
      end
    end

    describe 'multi-instance' do
      describe 'manifest' do
        let :multi_manifest do
          base_manifest + %(
            elasticsearch::user { '#{test_settings['security_user']}':
              password => '#{test_settings['security_password']}',
              roles => ['superuser'],
            }
          ) + @tls[:clients].each_with_index.map do |cert, i|
            format(%(
              elasticsearch::instance { 'es-%02d':
                ssl                  => true,
                ca_certificate       => '#{@tls[:ca][:cert][:path]}',
                certificate          => '#{cert[:cert][:path]}',
                private_key          => '#{cert[:key][:path]}',
                keystore_password    => '#{@keystore_password}',
                config => {
                  'discovery.zen.minimum_master_nodes' => %s,
                  'xpack.ssl.verification_mode' => 'none',
                  'http.port' => '92%02d',
                }
              }
            ), i + 1, @tls[:clients].length, i)
          end.join("\n") + format(%(
            Elasticsearch::Plugin { instances => %s, }
          ), @tls[:clients].each_with_index.map do |_, i|
            format('es-%02d', (i + 1))
          end.to_s)
        end

        it 'should apply cleanly' do
          apply_manifest multi_manifest, :catch_failures => true
        end

        it 'should be idempotent' do
          apply_manifest(
            multi_manifest,
            :catch_changes => true
          )
        end
      end

      describe port(test_settings['port_a']) do
        it 'open', :with_retries do
          should be_listening
        end
      end

      describe port(test_settings['port_b']) do
        it 'open', :with_retries do
          should be_listening
        end
      end

      describe server :container do
        describe http(
          "https://localhost:#{test_settings['port_a']}/_nodes",
          :basic_auth => [
            test_settings['security_user'],
            test_settings['security_password']
          ],
          :ssl => { :verify => false }
        ) do
          it 'clusters over TLS', :with_generous_retries do
            expect(
              JSON.parse(response.body)['nodes'].size
            ).to eq(2)
          end
        end
      end
    end
  end

  describe 'module removal' do
    describe 'manifest' do
      let :removal_manifest do
        format(%(
          class { 'elasticsearch' : ensure => absent, }

          Elasticsearch::Instance { ensure => absent, }
          elasticsearch::instance { %s : }
        ), @tls[:clients].each_with_index.map do |_, i|
          format('es-%02d', (i + 1))
        end.to_s)
      end

      it 'should apply cleanly' do
        apply_manifest removal_manifest, :catch_failures => true
      end
    end
  end
end
