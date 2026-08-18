describe file("/tmp/chef-kitchen-example") do
  it { should exist }
  its("content") { should match(/test-env/) }
end
