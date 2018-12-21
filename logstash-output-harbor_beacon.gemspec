Gem::Specification.new do |s|
  s.name          = 'logstash-output-harbor_beacon'
  s.version       = '0.2.0'
  s.licenses      = ['Apache-2.0']
  s.summary       = 'Emit output messages (beacons) to Harbor Beacon service.'
  s.description   = 'This gem is a Logstash output plugin to be installed on top of the Logstash'\
                    'core  pipeline using $LS_HOME/bin/logstash-plugin install gemname.'\
                    'This gem is not a stand-alone program.'
  s.homepage      = 'https://docs.hrbr.io/'
  s.authors       = ['Harbor']
  s.email         = 'info@hrbr.io'
  s.require_paths = ['lib']

  # Files
  s.files = Dir['lib/**/*','spec/**/*','vendor/**/*','*.gemspec','*.md','CONTRIBUTORS','Gemfile','LICENSE','NOTICE.TXT']
   # Tests
  s.test_files = s.files.grep(%r{^(test|spec|features)/})

  # Special flag to let us know this is actually a logstash plugin
  s.metadata = { "logstash_plugin" => "true", "logstash_group" => "output" }

  # Gem dependencies
  s.add_runtime_dependency "logstash-core-plugin-api", "~> 2.0"
  s.add_runtime_dependency "logstash-mixin-http_client", ">= 6.0.0", "< 7.0.0"
  s.add_runtime_dependency "logstash-codec-plain", "~> 3.0"

  s.add_development_dependency "logstash-devutils", "~> 1.3"
  s.add_development_dependency 'sinatra', '~> 1.4'
  s.add_development_dependency 'webrick', '~> 1.4'
end
