# frozen_string_literal: true

require_relative "../../support/active_record"
require_relative "../../support/kaminari"

RSpec.describe Riffle::Adapters::Kaminari, ".wrap_page_method" do
  before do
    User.create!(name: "alice")
    User.create!(name: "bob")
  end

  it "wraps .page so the resulting relation supports riffle_enabled" do
    Riffle::Current.enabled = false
    relation = User.page(1)
    expect(relation).to respond_to(:riffle_enabled)
  end

  it "sets riffle_enabled = true on the relation when Current.enabled" do
    Riffle::Current.enabled = true
    relation = User.page(1)
    expect(relation.riffle_enabled).to be true
  end

  it "leaves riffle_enabled falsey when Current is not enabled" do
    Riffle::Current.enabled = false
    relation = User.page(1)
    expect(relation.riffle_enabled).to be_falsey
  end

  it "is idempotent: re-wrapping does not raise or double-alias" do
    expect {
      described_class.wrap_page_method(User)
      described_class.wrap_page_method(User)
    }.not_to raise_error
  end

  it "no-ops on classes that do not respond to .page" do
    plain = Class.new
    expect {
      described_class.wrap_page_method(plain)
    }.not_to raise_error
    expect(plain.singleton_class.method_defined?(:page_without_riffle)).to be false
  end

  it "preserves Kaminari's own .page behavior (returns paginated relation)" do
    Riffle::Current.enabled = false
    relation = User.page(1).per(1)
    expect(relation.records.size).to eq(1)
  end
end
