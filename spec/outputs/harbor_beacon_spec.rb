require "logstash/devutils/rspec/spec_helper"
require "logstash/outputs/harbor_beacon"
require "logstash/codecs/plain"


class LogStash::Outputs::HarborBeacon
  attr_writer :agent
  attr_reader :request_tokens
end

describe LogStash::Outputs::HarborBeacon do

  let(:sample_event) { LogStash::Event.new({"message" => "hi"}) }

  let(:api_key) { "ABC" }
  let(:app_version_id) { "DEF" }
  let(:beacon_version_id) { "GHI" }
  let(:beacon_message_type) { "JKL" }
  let(:sample_config) { {"api_key" => api_key, "app_version_id" => app_version_id, "beacon_version_id" => beacon_version_id, "beacon_message_type" => beacon_message_type } }

  let(:output) { LogStash::Outputs::HarborBeacon.new(sample_config) }

  before do
      output.register
  end

  describe "receive message" do
    subject { output.receive(sample_event) }

    it "returns a string" do
      #expect(subject).to eq("Event received")
    end
  end

end
