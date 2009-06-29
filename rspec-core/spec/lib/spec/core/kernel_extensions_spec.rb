require File.expand_path(File.dirname(__FILE__) + "/../../../spec_helper")

describe Spec::Core::KernelExtensions do
  
  it "should be included in Object" do
    Object.included_modules.should include(Spec::Core::KernelExtensions)
  end
  
  it "should add a describe method to Object" do
    Object.should respond_to(:describe)
  end

end
