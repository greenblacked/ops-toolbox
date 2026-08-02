# Minimal recipe so `kitchen verify` has something to assert.

file "/tmp/chef-kitchen-example" do
  content "test-env\n"
  mode "0644"
end
