require 'spec_helper'

ActiveRecord::Schema.define(:version => 1) do
  create_table :companies, :force => true do |t|
    t.column :name, :string
  end

  create_table :users, :force => true do |t|
    t.column :name, :string
    t.column :company_id, :integer
  end

  create_table :tenants, :force => true do |t|
    t.column :name, :string
  end

  create_table :items, :force => true do |t|
    t.column :name, :string
    t.column :tenant_id, :integer
  end
end

class Company < ActiveRecord::Base
  has_many :users
end
class User < ActiveRecord::Base
  belongs_to :company
  belongs_to_multitenant :company
end

class Tenant < ActiveRecord::Base
  has_many :items
end
class Item < ActiveRecord::Base
  belongs_to :tenant
  belongs_to_multitenant
end

describe Multitenant do
  after { Multitenant.current_tenant = nil }
  
  it "shouldn't fail when no models defined" do
    models_backup = []
    Multitenant.instance_eval do
      models_backup = @models
      @models = nil
    end
    Multitenant.with_tenant @foo do
    end
    
    Multitenant.instance_eval do
      @models = models_backup
    end
  end

  it "should allow changing the tenant if it's nil" do
    user = User.create! :name => 'foo_user'

    Multitenant.with_tenant @foo do
      user.company = @foo
      user.save
      user.reload
      user.company.should == @foo
    end
  end
  
  describe 'Multitenant.current_tenant' do
    before { Multitenant.current_tenant = :foo }
    it { Multitenant.current_tenant == :foo }
  end

  describe 'Multitenant.with_tenant block' do
    before do
      @executed = false
      Multitenant.with_tenant :foo do
        Multitenant.current_tenant.should == :foo
        @executed = true
      end
    end
    it 'clears current_tenant after block runs' do
      Multitenant.current_tenant.should == nil
    end
    it 'yields the block' do
      @executed.should == true
    end    
  end

  describe 'Multitenant.with_tenant block that raises error' do
    before do
      @executed = false
      lambda {
        Multitenant.with_tenant :foo do
          @executed = true
          raise 'expected error'
        end
      }.should raise_error('expected error')
    end
    it 'clears current_tenant after block runs' do
      Multitenant.current_tenant.should == nil
    end
    it 'yields the block' do
      @executed.should == true
    end    
  end

  describe 'Aggressive Multitenant' do
    describe "When in tenant scope should create objects correctly" do
      before do
        @company = Company.create! :name => "bar"
        @company2 = Company.create! :name => "foo"

        Multitenant.with_tenant @company do
          @user = User.create! :name => "bar user"
        end
      end

      it "should not fail new operation but should set correct tenant" do
        Multitenant.with_tenant @company do
          user = User.new :name => "bar user 2"
          user.save.should be_true
          user.company.should == @company
        end
      end

      it "should set the tenant on new objects" do
        @user.company_id.should == @company.id
      end

      it "should prevent changing the tenant id through assigment to id" do
        pending "read only not implemented yet due to bugs"
        @user.company_id = @company2.id
        @user.company.should == @company
        @user.save.should be_true
        @user.company_id.should == @company.id
        @user.reload
        @user.company_id.should == @company.id
      end

      it "should prevent changing the tenant id through direct assigment" do
        pending "read only not implemented yet due to bugs"
        @user.company = @company2
        @user.company.should == @company
        @user.save.should be_true
        @user.company_id.should == @company.id
        @user.reload
        @user.company_id.should == @company.id
      end

     it "should allow setting company through association" do
        user = User.create! :name => "test"
        user.company = @company2
        user.save.should be_true
      end
    end

    describe "When current tenant is set" do
      before do
        @company = Company.create! :name => "foo"
        @company2 = Company.create! :name => "bar"
        @user = @company.users.create! :name => "foo user"
        @user2 = @company2.users.create! :name => "bar user"

        Multitenant.current_tenant = @company
      end

      it "should throw exception in case of getting objects from different tenant" do
        lambda { @user_reload = User.find @user2.id; }.should raise_error(ActiveRecord::RecordNotFound)
      end

      it "should prevent creating objects for other tenant" do
        lambda { @company2.users.create! }.should raise_error(Multitenant::AccessException)
      end

      it "should prevent updating to wrong tenant" do
        lambda { @user.company = @company2; @user.save }.should raise_error(Multitenant::AccessException)
      end
    end
  end
  
  describe 'User.all when current_tenant is set' do
    before do
      @company = Company.create!(:name => 'foo')
      @company2 = Company.create!(:name => 'bar')

      @user = @company.users.create! :name => 'bob'
      @user2 = @company2.users.create! :name => 'tim'
      Multitenant.with_tenant @company do
        @users = User.all
      end
    end
    it { @users.length.should == 1 }
    it { @users.should == [@user] }
  end

  describe 'Item.all when current_tenant is set' do
    before do
      @tenant = Tenant.create!(:name => 'foo')
      @tenant2 = Tenant.create!(:name => 'bar')

      @item = @tenant.items.create! :name => 'baz'
      @item2 = @tenant2.items.create! :name => 'booz'
      Multitenant.with_tenant @tenant do
        @items = Item.all
      end
    end
    it { @items.length.should == 1 }
    it { @items.should == [@item] }
  end

  describe 'creating new object when current_tenant is set' do
    before do
      @company = Company.create! :name => 'foo'
      Multitenant.with_tenant @company do
        @user = User.create! :name => 'jimmy'
      end
    end
    it 'should auto_populate the company' do
      @user.company_id.should == @company.id
    end
  end

  describe 'context change callbacks' do
    before do
      Multitenant.clear_on_context_change
      Multitenant.current_tenant = nil
      Multitenant.allow_dangerous_cross_tenants = nil
    end

    after do
      Multitenant.clear_on_context_change
      Multitenant.current_tenant = nil
      Multitenant.allow_dangerous_cross_tenants = nil
    end

    it 'calls callback once on tenant change nil→tenant' do
      calls = []
      cb = lambda { |prev, cur| calls << [prev, cur] }
      Multitenant.on_context_change(&cb)
      Multitenant.current_tenant = :t1
      calls.length.should == 1
      calls.first[0].should == {:tenant => nil, :is_cross_tenant => false}
      calls.first[1].should == {:tenant => :t1, :is_cross_tenant => false}
    end

    it 'does not call when reassigning the same tenant' do
      Multitenant.current_tenant = :t1
      calls = []
      cb = lambda { |prev, cur| calls << [prev, cur] }
      Multitenant.on_context_change(&cb)
      Multitenant.current_tenant = :t1
      calls.should be_empty
    end

    it 'calls on tenant change A→B with correct prev/cur' do
      Multitenant.current_tenant = :a
      calls = []
      cb = lambda { |prev, cur| calls << [prev, cur] }
      Multitenant.on_context_change(&cb)
      Multitenant.current_tenant = :b
      calls.length.should == 1
      calls.first[0].should == {:tenant => :a, :is_cross_tenant => false}
      calls.first[1].should == {:tenant => :b, :is_cross_tenant => false}
    end

    it 'calls on clearing tenant A→nil' do
      Multitenant.current_tenant = :a
      calls = []
      cb = lambda { |prev, cur| calls << [prev, cur] }
      Multitenant.on_context_change(&cb)
      Multitenant.current_tenant = nil
      calls.length.should == 1
      calls.first[0].should == {:tenant => :a, :is_cross_tenant => false}
      calls.first[1].should == {:tenant => nil, :is_cross_tenant => false}
    end

    it 'calls when allow cross tenant changes false/nil→true' do
      calls = []
      cb = lambda { |prev, cur| calls << [prev, cur] }
      Multitenant.on_context_change(&cb)
      Multitenant.allow_dangerous_cross_tenants = true
      calls.length.should == 1
      calls.first[0].should == {:tenant => nil, :is_cross_tenant => false}
      calls.first[1].should == {:tenant => nil, :is_cross_tenant => true}
    end

    it 'calls when allow cross tenant changes true→false' do
      Multitenant.allow_dangerous_cross_tenants = true
      calls = []
      cb = lambda { |prev, cur| calls << [prev, cur] }
      Multitenant.on_context_change(&cb)
      Multitenant.allow_dangerous_cross_tenants = false
      calls.length.should == 1
      calls.first[0].should == {:tenant => nil, :is_cross_tenant => true}
      calls.first[1].should == {:tenant => nil, :is_cross_tenant => false}
    end

    it 'does not call when allow cross tenant remains falsy (nil→nil)' do
      calls = []
      cb = lambda { |prev, cur| calls << [prev, cur] }
      Multitenant.on_context_change(&cb)
      Multitenant.allow_dangerous_cross_tenants = nil
      calls.should be_empty
    end

    it 'does not call when allow cross tenant remains the same (true→true)' do
      Multitenant.allow_dangerous_cross_tenants = true
      calls = []
      cb = lambda { |prev, cur| calls << [prev, cur] }
      Multitenant.on_context_change(&cb)
      Multitenant.allow_dangerous_cross_tenants = true
      calls.should be_empty
    end

    it 'does not call when changing extra_tenant_ids' do
      calls = []
      cb = lambda { |prev, cur| calls << [prev, cur] }
      Multitenant.on_context_change(&cb)
      Multitenant.extra_tenant_ids = [1, 2]
      calls.should be_empty
    end

    it 'with_tenant triggers enter notification only' do
      Multitenant.current_tenant = :old
      calls = []
      cb = lambda { |prev, cur| calls << [prev, cur] }
      Multitenant.on_context_change(&cb)
      Multitenant.with_tenant :new do
        # no-op
      end
      calls.length.should == 1
      calls[0][0].should == {:tenant => :old, :is_cross_tenant => false}
      calls[0][1].should == {:tenant => :new, :is_cross_tenant => false}
    end

    it 'with_tenant same tenant does not trigger notifications' do
      Multitenant.current_tenant = :same
      calls = []
      cb = lambda { |prev, cur| calls << [prev, cur] }
      Multitenant.on_context_change(&cb)
      Multitenant.with_tenant :same do
        # no-op
      end
      calls.should be_empty
    end

    it 'dangerous_cross_tenants suppresses tenant restore and allow exit notifications' do
      Multitenant.current_tenant = :acct
      Multitenant.allow_dangerous_cross_tenants = false
      calls = []
      cb = lambda { |prev, cur| calls << [prev, cur] }
      Multitenant.on_context_change(&cb)
      Multitenant.dangerous_cross_tenants do
        # no-op
      end
      calls.length.should == 2
      # 1) allow: false→true
      calls[0][0].should == {:tenant => :acct, :is_cross_tenant => false}
      calls[0][1].should == {:tenant => :acct, :is_cross_tenant => true}
      # 2) tenant: :acct→nil (while cross)
      calls[1][0].should == {:tenant => :acct, :is_cross_tenant => true}
      calls[1][1].should == {:tenant => nil, :is_cross_tenant => true}
    end

    it 'nested with_tenant triggers only enter notifications for each level' do
      Multitenant.current_tenant = :root
      calls = []
      cb = lambda { |prev, cur| calls << [prev, cur] }
      Multitenant.on_context_change(&cb)
      Multitenant.with_tenant :lvl1 do
        Multitenant.with_tenant :lvl2 do
          # no-op
        end
      end
      calls.length.should == 2
      calls[0][0].should == {:tenant => :root, :is_cross_tenant => false}
      calls[0][1].should == {:tenant => :lvl1, :is_cross_tenant => false}
      calls[1][0].should == {:tenant => :lvl1, :is_cross_tenant => false}
      calls[1][1].should == {:tenant => :lvl2, :is_cross_tenant => false}
    end

    it 'invokes multiple callbacks in registration order' do
      order = []
      cb1 = lambda { |prev, cur| order << 1 }
      cb2 = lambda { |prev, cur| order << 2 }
      Multitenant.on_context_change(&cb1)
      Multitenant.on_context_change(&cb2)
      Multitenant.current_tenant = :t
      order.should == [1, 2]
    end

    it 'remove_on_context_change unsubscribes the callback' do
      hits = 0
      cb = lambda { |prev, cur| hits += 1 }
      Multitenant.on_context_change(&cb)
      Multitenant.remove_on_context_change(cb)
      Multitenant.current_tenant = :t
      hits.should == 0
    end

    it 'raises from callback bubbles on tenant change' do
      cb = lambda { |prev, cur| raise 'boom' }
      Multitenant.on_context_change(&cb)
      lambda { Multitenant.current_tenant = :t }.should raise_error('boom')
    end

    it 'raises from callback bubbles on allow cross tenant change' do
      cb = lambda { |prev, cur| raise 'boom2' }
      Multitenant.on_context_change(&cb)
      lambda { Multitenant.allow_dangerous_cross_tenants = true }.should raise_error('boom2')
    end

    it 'state contains expected keys and values' do
      seen = nil
      cb = lambda { |prev, cur| seen = cur }
      Multitenant.on_context_change(&cb)
      Multitenant.current_tenant = :acct
      seen.keys.sort.should == [:is_cross_tenant, :tenant]
      seen[:tenant].should == :acct
      seen[:is_cross_tenant].should == false
    end
  end
end
