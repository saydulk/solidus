require 'spec_helper'

class FakeCalculator < Spree::Calculator
  def compute(computable)
    5
  end
end

describe Spree::Order, :type => :model do
  let(:user) { stub_model(Spree::LegacyUser, :email => "spree@example.com") }
  let(:order) { stub_model(Spree::Order, :user => user) }

  before do
    allow(Spree::LegacyUser).to receive_messages(:current => mock_model(Spree::LegacyUser, :id => 123))
  end

  context "#canceled_by" do
    let(:admin_user) { create :admin_user }
    let(:order) { create :order }

    before do
      allow(order).to receive(:cancel!)
    end

    subject { order.canceled_by(admin_user) }

    it 'should cancel the order' do
      expect(order).to receive(:cancel!)
      subject
    end

    it 'should save canceler_id' do
      subject
      expect(order.reload.canceler_id).to eq(admin_user.id)
    end

    it 'should save canceled_at' do
      subject
      expect(order.reload.canceled_at).to_not be_nil
    end

    it 'should have canceler' do
      subject
      expect(order.reload.canceler).to eq(admin_user)
    end
  end

  context "#create" do
    let(:order) { Spree::Order.create }

    it "should assign an order number" do
      expect(order.number).not_to be_nil
    end

    it 'should create a randomized 22 character token' do
      expect(order.guest_token.size).to eq(22)
    end
  end

  context "creates shipments cost" do
    let(:shipment) { double }

    before { allow(order).to receive_messages shipments: [shipment] }

    it "update and persist totals" do
      expect(shipment).to receive :update_amounts
      expect(order.updater).to receive :update_shipment_total
      expect(order.updater).to receive :persist_totals

      order.set_shipments_cost
    end
  end

  context "#finalize!" do
    let(:order) { Spree::Order.create(email: 'test@example.com') }

    before do
      order.update_column :state, 'complete'
    end

    it "should set completed_at" do
      expect(order).to receive(:touch).with(:completed_at)
      order.finalize!
    end

    it "should sell inventory units" do
      order.shipments.each do |shipment|
        expect(shipment).to receive(:update!)
        expect(shipment).to receive(:finalize!)
      end
      order.finalize!
    end

    it "should decrease the stock for each variant in the shipment" do
      order.shipments.each do |shipment|
        expect(shipment.stock_location).to receive(:decrease_stock_for_variant)
      end
      order.finalize!
    end

    it "should change the shipment state to ready if order is paid" do
      Spree::Shipment.create(order: order)
      order.shipments.reload

      allow(order).to receive_messages(:paid? => true, :complete? => true)
      order.finalize!
      order.reload # reload so we're sure the changes are persisted
      expect(order.shipment_state).to eq('ready')
    end

    after { Spree::Config.set :track_inventory_levels => true }
    it "should not sell inventory units if track_inventory_levels is false" do
      Spree::Config.set :track_inventory_levels => false
      expect(Spree::InventoryUnit).not_to receive(:sell_units)
      order.finalize!
    end

    it "should send an order confirmation email" do
      mail_message = double "Mail::Message"
      expect(Spree::OrderMailer).to receive(:confirm_email).with(order.id).and_return mail_message
      expect(mail_message).to receive :deliver
      order.finalize!
    end

    it "sets confirmation delivered when finalizing" do
      expect(order.confirmation_delivered?).to be false
      order.finalize!
      expect(order.confirmation_delivered?).to be true
    end

    it "should not send duplicate confirmation emails" do
      allow(order).to receive_messages(:confirmation_delivered? => true)
      expect(Spree::OrderMailer).not_to receive(:confirm_email)
      order.finalize!
    end

    it "should freeze all adjustments" do
      # Stub this method as it's called due to a callback
      # and it's irrelevant to this test
      allow(order).to receive :has_available_shipment
      allow(Spree::OrderMailer).to receive_message_chain :confirm_email, :deliver
      adjustments = [double]
      expect(order).to receive(:all_adjustments).and_return(adjustments)
      adjustments.each do |adj|
	      expect(adj).to receive(:close)
      end
      order.finalize!
    end

    context "order is considered risky" do
      before do
        allow(order).to receive_messages :is_risky? => true
      end

      it "should change state to risky" do
        expect(order).to receive(:considered_risky!)
        order.finalize!
      end

      context "and order is approved" do
        before do
          allow(order).to receive_messages :approved? => true
        end

        it "should leave order in complete state" do
          order.finalize!
          expect(order.state).to eq 'complete'
        end
      end
    end
  end

  context "insufficient_stock_lines" do
    let(:line_item) { mock_model Spree::LineItem, :insufficient_stock? => true }

    before { allow(order).to receive_messages(:line_items => [line_item]) }

    it "should return line_item that has insufficient stock on hand" do
      expect(order.insufficient_stock_lines.size).to eq(1)
      expect(order.insufficient_stock_lines.include?(line_item)).to be true
    end
  end

  describe '#ensure_line_item_variants_are_not_deleted' do
    subject { order.ensure_line_item_variants_are_not_deleted }

    let(:order) { create :order_with_line_items }

    context 'when variant is destroyed' do
      before do
        allow(order).to receive(:restart_checkout_flow)
        order.line_items.first.variant.destroy
      end

      it 'should restart checkout flow' do
        expect(order).to receive(:restart_checkout_flow).once
        subject
      end

      it 'should have error message' do
        subject
        expect(order.errors[:base]).to include(Spree.t(:deleted_variants_present))
      end

      it 'should be false' do
        expect(subject).to be_falsey
      end
    end

    context 'when no variants are destroyed' do
      it 'should not restart checkout' do
        expect(order).to receive(:restart_checkout_flow).never
        subject
      end

      it 'should be true' do
        expect(subject).to be_truthy
      end
    end
  end

  describe '#ensure_line_items_are_in_stock' do
    subject { order.ensure_line_items_are_in_stock }

    let(:line_item) { mock_model Spree::LineItem, :insufficient_stock? => true }

    before do
      allow(order).to receive(:restart_checkout_flow)
      allow(order).to receive_messages(:line_items => [line_item])
    end

    it 'should restart checkout flow' do
      expect(order).to receive(:restart_checkout_flow).once
      subject
    end

    it 'should have error message' do
      subject
      expect(order.errors[:base]).to include(Spree.t(:insufficient_stock_lines_present))
    end

    it 'should be false' do
      expect(subject).to be_falsey
    end
  end

  context "empty!" do
    let(:order) { stub_model(Spree::Order, item_count: 2) }

    before do
      allow(order).to receive_messages(:line_items => line_items = [1, 2])
      allow(order).to receive_messages(:adjustments => adjustments = [])
    end

    it "clears out line items, adjustments and update totals" do
      expect(order.line_items).to receive(:destroy_all)
      expect(order.adjustments).to receive(:destroy_all)
      expect(order.shipments).to receive(:destroy_all)
      expect(order.updater).to receive(:update_totals)
      expect(order.updater).to receive(:persist_totals)

      order.empty!
      expect(order.item_total).to eq 0
    end
  end

  context "#display_outstanding_balance" do
    it "returns the value as a spree money" do
      allow(order).to receive(:outstanding_balance) { 10.55 }
      expect(order.display_outstanding_balance).to eq(Spree::Money.new(10.55))
    end
  end

  context "#display_item_total" do
    it "returns the value as a spree money" do
      allow(order).to receive(:item_total) { 10.55 }
      expect(order.display_item_total).to eq(Spree::Money.new(10.55))
    end
  end

  context "#display_adjustment_total" do
    it "returns the value as a spree money" do
      order.adjustment_total = 10.55
      expect(order.display_adjustment_total).to eq(Spree::Money.new(10.55))
    end
  end

  context "#display_total" do
    it "returns the value as a spree money" do
      order.total = 10.55
      expect(order.display_total).to eq(Spree::Money.new(10.55))
    end
  end

  context "#currency" do
    context "when object currency is ABC" do
      before { order.currency = "ABC" }

      it "returns the currency from the object" do
        expect(order.currency).to eq("ABC")
      end
    end

    context "when object currency is nil" do
      before { order.currency = nil }

      it "returns the globally configured currency" do
        expect(order.currency).to eq("USD")
      end
    end
  end

  # Regression tests for #2179
  context "#merge!" do
    let(:variant) { create(:variant) }
    let(:order_1) { Spree::Order.create }
    let(:order_2) { Spree::Order.create }

    it "destroys the other order" do
      order_1.merge!(order_2)
      expect { order_2.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end

    context "user is provided" do
      it "assigns user to new order" do
        order_1.merge!(order_2, user)
        expect(order_1.user).to eq user
      end
    end

    context "merging together two orders with line items for the same variant" do
      before do
        order_1.contents.add(variant, 1)
        order_2.contents.add(variant, 1)
      end

      specify do
        order_1.merge!(order_2)
        expect(order_1.line_items.count).to eq(1)

        line_item = order_1.line_items.first
        expect(line_item.quantity).to eq(2)
        expect(line_item.variant_id).to eq(variant.id)
      end

    end

    context "merging using extension-specific line_item_comparison_hooks" do
      before do
        Spree::Order.register_line_item_comparison_hook(:foos_match)
        allow(Spree::Variant).to receive(:price_modifier_amount).and_return(0.00)
      end

      after do
        # reset to avoid test pollution
        Spree::Order.line_item_comparison_hooks = Set.new
      end

      context "2 equal line items" do
        before do
          @line_item_1 = order_1.contents.add(variant, 1, {foos: {}})
          @line_item_2 = order_2.contents.add(variant, 1, {foos: {}})
        end

        specify do
          expect(order_1).to receive(:foos_match).with(@line_item_1, kind_of(Hash)).and_return(true)
          order_1.merge!(order_2)
          expect(order_1.line_items.count).to eq(1)

          line_item = order_1.line_items.first
          expect(line_item.quantity).to eq(2)
          expect(line_item.variant_id).to eq(variant.id)
        end
      end

      context "2 different line items" do
        before do
          allow(order_1).to receive(:foos_match).and_return(false)

          order_1.contents.add(variant, 1, {foos: {}})
          order_2.contents.add(variant, 1, {foos: {bar: :zoo}})
        end

        specify do
          order_1.merge!(order_2)
          expect(order_1.line_items.count).to eq(2)

          line_item = order_1.line_items.first
          expect(line_item.quantity).to eq(1)
          expect(line_item.variant_id).to eq(variant.id)

          line_item = order_1.line_items.last
          expect(line_item.quantity).to eq(1)
          expect(line_item.variant_id).to eq(variant.id)
        end
      end
    end

    context "merging together two orders with different line items" do
      let(:variant_2) { create(:variant) }

      before do
        order_1.contents.add(variant, 1)
        order_2.contents.add(variant_2, 1)
      end

      specify do
        order_1.merge!(order_2)
        line_items = order_1.line_items.reload
        expect(line_items.count).to eq(2)

        expect(order_1.item_count).to eq 2
        expect(order_1.item_total).to eq line_items.map(&:amount).sum

        # No guarantee on ordering of line items, so we do this:
        expect(line_items.pluck(:quantity)).to match_array([1, 1])
        expect(line_items.pluck(:variant_id)).to match_array([variant.id, variant_2.id])
      end
    end
  end

  context "add_update_hook" do
    before do
      Spree::Order.class_eval do
        register_update_hook :add_awesome_sauce
      end
    end

    after do
      Spree::Order.update_hooks = Set.new
    end

    it "calls hook during update" do
      order = create(:order)
      expect(order).to receive(:add_awesome_sauce)
      order.update!
    end

    it "calls hook during finalize" do
      order = create(:order)
      expect(order).to receive(:add_awesome_sauce)
      order.finalize!
    end
  end

  context "ensure shipments will be updated" do
    before do
      Spree::Shipment.create!(order: order)
    end

    ['payment', 'confirm'].each do |order_state|
      context "when ther order is in the #{order_state} state" do
        before do
          order.state = order_state
          order.shipments.create!
        end

        it "destroys current shipments" do
          order.ensure_updated_shipments
          expect(order.shipments).to be_empty
        end

        it "puts order back in address state" do
          order.ensure_updated_shipments
          expect(order.state).to eql "cart"
        end

        it "resets shipment_total" do
          order.update_column(:shipment_total, 5)
          order.ensure_updated_shipments
          expect(order.shipment_total).to eq(0)
        end
      end
    end

    context 'when the order is in address state' do
      before do
        order.state = 'address'
        order.shipments.create!
      end

      it "destroys current shipments" do
        order.ensure_updated_shipments
        expect(order.shipments).to be_empty
      end

      it "resets shipment_total" do
        order.update_column(:shipment_total, 5)
        order.ensure_updated_shipments
        expect(order.shipment_total).to eq(0)
      end

      it "puts the order in the cart state" do
        order.ensure_updated_shipments
        expect(order.state).to eq "cart"
      end
    end

    context 'when the order is completed' do
      before do
        order.state = 'complete'
        order.completed_at = Time.now
        order.update_column(:shipment_total, 5)
        order.shipments.create!
      end

      it "does not destroy the current shipments" do
        expect {
          order.ensure_updated_shipments
        }.not_to change { order.shipments }
      end

      it "does not reset the shipment total" do
        expect {
          order.ensure_updated_shipments
        }.not_to change { order.shipment_total }
      end

      it "does not put the order back in the address state" do
        expect {
          order.ensure_updated_shipments
        }.not_to change { order.state }
      end
    end
  end

  describe "#tax_address" do
    before { Spree::Config[:tax_using_ship_address] = tax_using_ship_address }
    subject { order.tax_address }

    context "when tax_using_ship_address is true" do
      let(:tax_using_ship_address) { true }

      it 'returns ship_address' do
        expect(subject).to eq(order.ship_address)
      end
    end

    context "when tax_using_ship_address is not true" do
      let(:tax_using_ship_address) { false }

      it "returns bill_address" do
        expect(subject).to eq(order.bill_address)
      end
    end
  end

  describe "#restart_checkout_flow" do
    it "updates the state column to the first checkout_steps value" do
      order = create(:order_with_totals, state: "delivery")
      expect(order.checkout_steps).to eql ["address", "delivery", "confirm", "complete"]
      expect{ order.restart_checkout_flow }.to change{order.state}.from("delivery").to("address")
    end

    context "without line items" do
      it "updates the state column to cart" do
        order = create(:order, state: "delivery")
        expect{ order.restart_checkout_flow }.to change{order.state}.from("delivery").to("cart")
      end
    end
  end

  # Regression tests for #4072
  context "#state_changed" do
    let(:order) { FactoryGirl.create(:order) }

    it "logs state changes" do
      order.update_column(:payment_state, 'balance_due')
      order.payment_state = 'paid'
      expect(order.state_changes).to be_empty
      order.state_changed('payment')
      state_change = order.state_changes.find_by(:name => 'payment')
      expect(state_change.previous_state).to eq('balance_due')
      expect(state_change.next_state).to eq('paid')
    end

    it "does not do anything if state does not change" do
      order.update_column(:payment_state, 'balance_due')
      expect(order.state_changes).to be_empty
      order.state_changed('payment')
      expect(order.state_changes).to be_empty
    end
  end

  # Regression test for #4199
  context "#available_payment_methods" do
    it "includes frontend payment methods" do
      payment_method = Spree::PaymentMethod.create!({
        :name => "Fake",
        :active => true,
        :display_on => "front_end",
        :environment => Rails.env
      })
      expect(order.available_payment_methods).to include(payment_method)
    end

    it "includes 'both' payment methods" do
      payment_method = Spree::PaymentMethod.create!({
        :name => "Fake",
        :active => true,
        :display_on => "both",
        :environment => Rails.env
      })
      expect(order.available_payment_methods).to include(payment_method)
    end

    it "does not include a payment method twice if display_on is blank" do
      payment_method = Spree::PaymentMethod.create!({
        :name => "Fake",
        :active => true,
        :display_on => "both",
        :environment => Rails.env
      })
      expect(order.available_payment_methods.count).to eq(1)
      expect(order.available_payment_methods).to include(payment_method)
    end
  end

  context "#apply_free_shipping_promotions" do
    it "calls out to the FreeShipping promotion handler" do
      shipment = double('Shipment')
      allow(order).to receive_messages :shipments => [shipment]
      expect(Spree::PromotionHandler::FreeShipping).to receive(:new).and_return(handler = double)
      expect(handler).to receive(:activate)

      expect(Spree::ItemAdjustments).to receive(:new).with(shipment).and_return(adjuster = double)
      expect(adjuster).to receive(:update)

      expect(order.updater).to receive(:update_shipment_total)
      expect(order.updater).to receive(:persist_totals)
      order.apply_free_shipping_promotions
    end
  end


  context "#products" do
    before :each do
      @variant1 = mock_model(Spree::Variant, :product => "product1")
      @variant2 = mock_model(Spree::Variant, :product => "product2")
      @line_items = [mock_model(Spree::LineItem, :product => "product1", :variant => @variant1, :variant_id => @variant1.id, :quantity => 1),
                     mock_model(Spree::LineItem, :product => "product2", :variant => @variant2, :variant_id => @variant2.id, :quantity => 2)]
      allow(order).to receive_messages(:line_items => @line_items)
    end

    it "contains?" do
      expect(order.contains?(@variant1)).to be true
    end

    it "gets the quantity of a given variant" do
      expect(order.quantity_of(@variant1)).to eq(1)

      @variant3 = mock_model(Spree::Variant, :product => "product3")
      expect(order.quantity_of(@variant3)).to eq(0)
    end

    it "can find a line item matching a given variant" do
      expect(order.find_line_item_by_variant(@variant1)).not_to be_nil
      expect(order.find_line_item_by_variant(mock_model(Spree::Variant))).to be_nil
    end

    context "match line item with options" do
      before do
        Spree::Order.register_line_item_comparison_hook(:foos_match)
      end

      after do
        # reset to avoid test pollution
        Spree::Order.line_item_comparison_hooks = Set.new
      end

      it "matches line item when options match" do
        allow(order).to receive(:foos_match).and_return(true)
        expect(order.line_item_options_match(@line_items.first, {foos: {bar: :zoo}})).to be true
      end

      it "does not match line item without options" do
        allow(order).to receive(:foos_match).and_return(false)
        expect(order.line_item_options_match(@line_items.first, {})).to be false
      end
    end
  end

  context "#generate_order_number" do
    context "when no configure" do
      let(:default_length) { Spree::Order::ORDER_NUMBER_LENGTH + Spree::Order::ORDER_NUMBER_PREFIX.length }
      subject(:order_number) { order.generate_order_number }

      describe '#class' do
        subject { super().class }
        it { is_expected.to eq String }
      end

      describe '#length' do
        subject { super().length }
        it { is_expected.to eq default_length }
      end
      it { is_expected.to match /^#{Spree::Order::ORDER_NUMBER_PREFIX}/ }
    end

    context "when length option is 5" do
      let(:option_length) { 5 + Spree::Order::ORDER_NUMBER_PREFIX.length }
      it "should be option length for order number" do
        expect(order.generate_order_number(length: 5).length).to eq option_length
      end
    end

    context "when letters option is true" do
      it "generates order number include letter" do
        expect(order.generate_order_number(length: 100, letters: true)).to match /[A-Z]/
      end
    end

    context "when prefix option is 'P'" do
      it "generates order number and it prefix is 'P'" do
        expect(order.generate_order_number(prefix: 'P')).to match /^P/
      end
    end
  end

  context "#associate_user!" do
    let!(:user) { FactoryGirl.create(:user) }

    it "should associate a user with a persisted order" do
      order = FactoryGirl.create(:order_with_line_items, created_by: nil)
      order.user = nil
      order.email = nil
      order.associate_user!(user)
      expect(order.user).to eq(user)
      expect(order.email).to eq(user.email)
      expect(order.created_by).to eq(user)

      # verify that the changes we made were persisted
      order.reload
      expect(order.user).to eq(user)
      expect(order.email).to eq(user.email)
      expect(order.created_by).to eq(user)
    end

    it "should not overwrite the created_by if it already is set" do
      creator = create(:user)
      order = FactoryGirl.create(:order_with_line_items, created_by: creator)

      order.user = nil
      order.email = nil
      order.associate_user!(user)
      expect(order.user).to eq(user)
      expect(order.email).to eq(user.email)
      expect(order.created_by).to eq(creator)

      # verify that the changes we made were persisted
      order.reload
      expect(order.user).to eq(user)
      expect(order.email).to eq(user.email)
      expect(order.created_by).to eq(creator)
    end

    it "should associate a user with a non-persisted order" do
      order = Spree::Order.new

      expect do
        order.associate_user!(user)
      end.to change { [order.user, order.email] }.from([nil, nil]).to([user, user.email])
    end

    it "should not persist an invalid address" do
      address = Spree::Address.new
      order.user = nil
      order.email = nil
      order.ship_address = address
      expect do
        order.associate_user!(user)
      end.not_to change { address.persisted? }.from(false)
    end
  end

  context "#can_ship?" do
    let(:order) { Spree::Order.create }

    it "should be true for order in the 'complete' state" do
      allow(order).to receive_messages(:complete? => true)
      expect(order.can_ship?).to be true
    end

    it "should be true for order in the 'resumed' state" do
      allow(order).to receive_messages(:resumed? => true)
      expect(order.can_ship?).to be true
    end

    it "should be true for an order in the 'awaiting return' state" do
      allow(order).to receive_messages(:awaiting_return? => true)
      expect(order.can_ship?).to be true
    end

    it "should be true for an order in the 'returned' state" do
      allow(order).to receive_messages(:returned? => true)
      expect(order.can_ship?).to be true
    end

    it "should be false if the order is neither in the 'complete' nor 'resumed' state" do
      allow(order).to receive_messages(:resumed? => false, :complete? => false)
      expect(order.can_ship?).to be false
    end
  end

  context "#completed?" do
    it "should indicate if order is completed" do
      order.completed_at = nil
      expect(order.completed?).to be false

      order.completed_at = Time.now
      expect(order.completed?).to be true
    end
  end

  context "#allow_checkout?" do
    it "should be true if there are line_items in the order" do
      allow(order).to receive_message_chain(:line_items, :count => 1)
      expect(order.checkout_allowed?).to be true
    end
    it "should be false if there are no line_items in the order" do
      allow(order).to receive_message_chain(:line_items, :count => 0)
      expect(order.checkout_allowed?).to be false
    end
  end

  context "#amount" do
    before do
      @order = create(:order, :user => user)
      @order.line_items = [create(:line_item, :price => 1.0, :quantity => 2),
                           create(:line_item, :price => 1.0, :quantity => 1)]
    end
    it "should return the correct lum sum of items" do
      expect(@order.amount).to eq(3.0)
    end
  end

  context "#backordered?" do
    it 'is backordered if one of the shipments is backordered' do
      allow(order).to receive_messages(:shipments => [mock_model(Spree::Shipment, :backordered? => false),
                                mock_model(Spree::Shipment, :backordered? => true)])
      expect(order).to be_backordered
    end
  end

  context "#can_cancel?" do
    it "should be false for completed order in the canceled state" do
      order.state = 'canceled'
      order.shipment_state = 'ready'
      order.completed_at = Time.now
      expect(order.can_cancel?).to be false
    end

    it "should be true for completed order with no shipment" do
      order.state = 'complete'
      order.shipment_state = nil
      order.completed_at = Time.now
      expect(order.can_cancel?).to be true
    end
  end

  context "#tax_total" do
    it "adds included tax and additional tax" do
      allow(order).to receive_messages(:additional_tax_total => 10, :included_tax_total => 20)

      expect(order.tax_total).to eq 30
    end
  end

  # Regression test for #4923
  context "locking" do
    let(:order) { Spree::Order.create } # need a persisted in order to test locking

    it 'can lock' do
      expect { order.with_lock {} }.to_not raise_error
    end
  end

  describe "#pre_tax_item_amount" do
    it "sums all of the line items' pre tax amounts" do
      subject.line_items = [
        Spree::LineItem.new(price: 10, quantity: 2, pre_tax_amount: 5.0),
        Spree::LineItem.new(price: 30, quantity: 1, pre_tax_amount: 14.0),
      ]

      expect(subject.pre_tax_item_amount).to eq 19.0
    end
  end

  describe '#quantity' do
    # Uses a persisted record, as the quantity is retrieved via a DB count
    let(:order) { create :order_with_line_items, line_items_count: 3 }

    it 'sums the quantity of all line items' do
      expect(order.quantity).to eq 3
    end
  end

  describe '#has_non_reimbursement_related_refunds?' do
    subject do
      order.has_non_reimbursement_related_refunds?
    end

    context 'no refunds exist' do
      it { is_expected.to eq false }
    end

    context 'a non-reimbursement related refund exists' do
      let(:order) { refund.payment.order }
      let(:refund) { create(:refund, reimbursement_id: nil, amount: 5) }

      it { is_expected.to eq true }
    end

    context 'an old-style refund exists' do
      let(:order) { create(:order_ready_to_ship) }
      let(:payment) { order.payments.first.tap { |p| allow(p).to receive_messages(profiles_supported: false) } }
      let!(:refund_payment) {
        build(:payment, amount: -1, order: order, state: 'completed', source: payment).tap do |p|
          allow(p).to receive_messages(profiles_supported?: false)
          p.save!
        end
      }

      it { is_expected.to eq true }
    end

    context 'a reimbursement related refund exists' do
      let(:order) { refund.payment.order }
      let(:refund) { create(:refund, reimbursement_id: 123, amount: 5)}

      it { is_expected.to eq false }
    end
  end

  describe "#create_proposed_shipments" do
    it "assigns the coordinator returned shipments to its shipments" do
      shipment = build(:shipment)
      allow_any_instance_of(Spree::Stock::Coordinator).to receive(:shipments).and_return([shipment])
      subject.create_proposed_shipments
      expect(subject.shipments).to eq [shipment]
    end
  end

  describe "#all_inventory_units_returned?" do
    let(:order) { create(:order_with_line_items, line_items_count: 3) }

    subject { order.all_inventory_units_returned? }

    context "all inventory units are returned" do
      before { order.inventory_units.update_all(state: 'returned') }

      it "is true" do
        expect(subject).to eq true
      end
    end

    context "some inventory units are returned" do
      before do
        order.inventory_units.first.update_attribute(:state, 'returned')
      end

      it "is false" do
        expect(subject).to eq false
      end
    end

    context "no inventory units are returned" do
      it "is false" do
        expect(subject).to eq false
      end
    end
  end

  describe "#unreturned_exchange?" do
    let(:order) { create(:order_with_line_items) }
    subject { order.unreturned_exchange? }

    context "the order does not have a shipment" do
      before { order.shipments.destroy_all }

      it { should be false }
    end

    context "shipment created after order" do
      it { should be false }
    end

    context "shipment created before order" do
      before do
        order.shipments.first.update_attributes!(created_at: order.created_at - 1.day)
      end

      it { should be true }
    end
  end

  describe '.unreturned_exchange' do
    let(:order) { create(:order_with_line_items) }
    subject { described_class.unreturned_exchange }

    it 'includes orders that have a shipment created prior to the order' do
      order.shipments.first.update_attributes!(created_at: order.created_at - 1.day)
      expect(subject).to include order
    end

    it 'excludes orders that were created prior to their shipment' do
      expect(subject).not_to include order
    end

    it 'excludes orders with no shipment' do
      order.shipments.destroy_all
      expect(subject).not_to include order
    end
  end
end
