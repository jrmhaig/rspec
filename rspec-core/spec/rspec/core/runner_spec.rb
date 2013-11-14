require 'spec_helper'
require 'rspec/core/drb_command_line'

module RSpec::Core
  describe Runner do
    describe 'invocation' do
      before {
        # Simulate invoking the suite like exe/rspec does.
        RSpec::Core::Runner.stub(:run)
        RSpec::Core::Runner.invoke
      }

      it 'does not autorun after having been invoked' do
        RSpec::Core::Runner.should_not_receive(:at_exit)
        RSpec::Core::Runner.autorun
      end

      it 'prints a warning when autorun is attempted' do
        STDERR.should_receive(:puts).with("\nDeprecated: requiring rspec/autorun has no effect when running rspec from the command line.")
        RSpec::Core::Runner.autorun
      end
    end

    describe 'at_exit' do
      it 'sets an at_exit hook if none is already set' do
        RSpec::Core::Runner.stub(:autorun_disabled?).and_return(false)
        RSpec::Core::Runner.stub(:installed_at_exit?).and_return(false)
        RSpec::Core::Runner.stub(:running_in_drb?).and_return(false)
        RSpec::Core::Runner.stub(:invoke)
        RSpec::Core::Runner.should_receive(:at_exit)
        RSpec::Core::Runner.autorun
      end

      it 'does not set the at_exit hook if it is already set' do
        RSpec::Core::Runner.stub(:autorun_disabled?).and_return(false)
        RSpec::Core::Runner.stub(:installed_at_exit?).and_return(true)
        RSpec::Core::Runner.stub(:running_in_drb?).and_return(false)
        RSpec::Core::Runner.should_receive(:at_exit).never
        RSpec::Core::Runner.autorun
      end
    end

    describe "#running_in_drb?" do
      it "returns true if drb server is started with 127.0.0.1" do
        allow(::DRb).to receive(:current_server).and_return(double(:uri => "druby://127.0.0.1:0000/"))

        expect(RSpec::Core::Runner.running_in_drb?).to be_truthy
      end

      it "returns true if drb server is started with localhost" do
        allow(::DRb).to receive(:current_server).and_return(double(:uri => "druby://localhost:0000/"))

        expect(RSpec::Core::Runner.running_in_drb?).to be_truthy
      end

      it "returns true if drb server is started with another local ip address" do
        allow(::DRb).to receive(:current_server).and_return(double(:uri => "druby://192.168.0.1:0000/"))
        allow(::IPSocket).to receive(:getaddress).and_return("192.168.0.1")

        expect(RSpec::Core::Runner.running_in_drb?).to be_truthy
      end

      it "returns false if no drb server is running" do
        ::DRb.stub(:current_server).and_raise(::DRb::DRbServerNotFound)

        expect(RSpec::Core::Runner.running_in_drb?).to be_falsey
      end
    end

    describe "#invoke" do
      let(:runner) { RSpec::Core::Runner }

      it "runs the specs via #run" do
        allow(runner).to receive(:exit)
        expect(runner).to receive(:run)
        runner.invoke
      end

      it "doesn't exit on success" do
        allow(runner).to receive(:run) { 0 }
        expect(runner).to_not receive(:exit)
        runner.invoke
      end

      it "exits with #run's status on failure" do
        allow(runner).to receive(:run) { 123 }
        expect(runner).to receive(:exit).with(123)
        runner.invoke
      end
    end

    describe "#run" do
      let(:err) { StringIO.new }
      let(:out) { StringIO.new }

      it "tells RSpec to reset" do
        RSpec.configuration.stub(:files_to_run => [], :warn => nil)
        RSpec.should_receive(:reset)
        RSpec::Core::Runner.run([], err, out)
      end

      context "with --drb or -X" do
        before(:each) do
          @options = RSpec::Core::ConfigurationOptions.new(%w[--drb --drb-port 8181 --color])
          RSpec::Core::ConfigurationOptions.stub(:new) { @options }
        end

        def run_specs
          RSpec::Core::Runner.run(%w[ --drb ], err, out)
        end

        context 'and a DRb server is running' do
          it "builds a DRbCommandLine and runs the specs" do
            drb_proxy = double(RSpec::Core::DRbCommandLine, :run => true)
            drb_proxy.should_receive(:run).with(err, out)

            RSpec::Core::DRbCommandLine.should_receive(:new).and_return(drb_proxy)

            run_specs
          end
        end

        context 'and a DRb server is not running' do
          before(:each) do
            RSpec::Core::DRbCommandLine.should_receive(:new).and_raise(DRb::DRbConnError)
          end

          it "outputs a message" do
            RSpec.configuration.stub(:files_to_run) { [] }
            err.should_receive(:puts).with(
              "No DRb server is running. Running in local process instead ..."
            )
            run_specs
          end

          it "builds a CommandLine and runs the specs" do
            process_proxy = double(RSpec::Core::CommandLine, :run => 0)
            process_proxy.should_receive(:run).with(err, out)

            RSpec::Core::CommandLine.should_receive(:new).and_return(process_proxy)

            run_specs
          end
        end
      end
    end
  end
end
