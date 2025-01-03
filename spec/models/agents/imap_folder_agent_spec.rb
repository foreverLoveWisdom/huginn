require 'rails_helper'
require 'time'

describe Agents::ImapFolderAgent do
  module MessageMixin
    def folder
      'INBOX'
    end

    def uidvalidity
      100
    end

    def has_attachment?
      false
    end

    def body_parts(mime_types = %(text/plain text/enriched text/html))
      mime_types.map do |type|
        all_parts.find do |part|
          part.mime_type == type
        end
      end.compact.map! do |part|
        part.extend(Agents::ImapFolderAgent::Message::Scrubbed)
      end
    end

    def uid; end

    def raw_mail; end

    def delete; end

    def mark_as_read; end

    include Agents::ImapFolderAgent::Message::Scrubbed
  end

  describe 'checking IMAP' do
    let(:valid_options) do
      {
        'expected_update_period_in_days' => 1,
        'host' => 'mail.example.net',
        'ssl' => true,
        'username' => 'foo',
        'password' => 'bar',
        'folders' => ['INBOX'],
        'conditions' => {}
      }
    end

    let(:mails) do
      [
        Mail.read(Rails.root.join('spec/data_fixtures/imap1.eml')).tap do |mail|
          mail.extend(MessageMixin)
          allow(mail).to receive(:uid).and_return(1)
          allow(mail).to receive(:raw_mail).and_return(mail.encoded)
        end,
        Mail.read(Rails.root.join('spec/data_fixtures/imap2.eml')).tap do |mail|
          mail.extend(MessageMixin)
          allow(mail).to receive(:uid).and_return(2)
          allow(mail).to receive(:has_attachment?).and_return(true)
          allow(mail).to receive(:raw_mail).and_return(mail.encoded)
        end
      ]
    end

    let(:expected_payloads) do
      [
        {
          'message_id' => 'foo.123@mail.example.jp',
          'folder' => 'INBOX',
          'from' => 'nanashi.gombeh@example.jp',
          'to' => ['jane.doe@example.com', 'john.doe@example.com'],
          'cc' => [],
          'date' => '2014-05-09T16:00:00+09:00',
          'subject' => 'some subject',
          'body' => "Some plain text\nSome second line\n",
          'has_attachment' => false,
          'matches' => {},
          'mime_type' => 'text/plain'
        },
        {
          'message_id' => 'bar.456@mail.example.com',
          'folder' => 'INBOX',
          'from' => 'john.doe@example.com',
          'to' => ['jane.doe@example.com', 'nanashi.gombeh@example.jp'],
          'cc' => [],
          'subject' => 'Re: some subject',
          'body' => "Some reply\n",
          'date' => '2014-05-09T17:00:00+09:00',
          'has_attachment' => true,
          'matches' => {},
          'mime_type' => 'text/plain'
        }
      ]
    end

    before do
      @checker = Agents::ImapFolderAgent.new(name: 'Example', options: valid_options, keep_events_for: 2.days)
      @checker.user = users(:bob)
      @checker.save!

      allow(@checker).to receive(:each_unread_mail) { |&yielder|
        seen = @checker.lastseen
        notified = @checker.notified
        mails.each do |mail|
          yielder[mail, notified]
          seen[mail.uidvalidity] = mail.uid
        end
        @checker.lastseen = seen
        @checker.notified = notified
        nil
      }
    end

    describe 'validations' do
      before do
        expect(@checker).to be_valid
      end

      it 'should validate the integer fields' do
        @checker.options['expected_update_period_in_days'] = 'nonsense'
        expect(@checker).not_to be_valid

        @checker.options['expected_update_period_in_days'] = '2'
        expect(@checker).to be_valid

        @checker.options['port'] = -1
        expect(@checker).not_to be_valid

        @checker.options['port'] = 'imap'
        expect(@checker).not_to be_valid

        @checker.options['port'] = '143'
        expect(@checker).to be_valid

        @checker.options['port'] = 993
        expect(@checker).to be_valid
      end

      it 'should validate the boolean fields' do
        %w[ssl mark_as_read].each do |key|
          @checker.options[key] = 1
          expect(@checker).not_to be_valid

          @checker.options[key] = false
          expect(@checker).to be_valid

          @checker.options[key] = 'true'
          expect(@checker).to be_valid

          @checker.options[key] = ''
          expect(@checker).to be_valid
        end
      end

      it 'should validate regexp conditions' do
        @checker.options['conditions'] = {
          'subject' => '(foo'
        }
        expect(@checker).not_to be_valid

        @checker.options['conditions'] = {
          'body' => '***'
        }
        expect(@checker).not_to be_valid

        @checker.options['conditions'] = {
          'subject' => '\ARe:',
          'body' => '(?<foo>http://\S+)'
        }
        expect(@checker).to be_valid
      end
    end

    describe '#check' do
      it 'should check for mails and save memory' do
        expect { @checker.check }.to change { Event.count }.by(2)
        expect(@checker.notified.sort).to eq(mails.map(&:message_id).sort)
        expect(@checker.lastseen).to eq(mails.each_with_object(@checker.make_seen) do |mail, seen|
          seen[mail.uidvalidity] = mail.uid
        end)

        expect(Event.last(2).map(&:payload)).to eq expected_payloads

        expect { @checker.check }.not_to(change { Event.count })
      end

      it 'should narrow mails by To' do
        @checker.options['conditions']['to'] = 'John.Doe@*'

        expect { @checker.check }.to change { Event.count }.by(1)
        expect(@checker.notified.sort).to eq([mails.first.message_id])
        expect(@checker.lastseen).to eq(mails.each_with_object(@checker.make_seen) do |mail, seen|
          seen[mail.uidvalidity] = mail.uid
        end)

        expect(Event.last.payload).to eq(expected_payloads.first)

        expect { @checker.check }.not_to(change { Event.count })
      end

      it 'should not fail when a condition on Cc is given and a mail does not have the field' do
        @checker.options['conditions']['cc'] = 'John.Doe@*'

        expect do
          expect { @checker.check }.not_to(change { Event.count })
        end.not_to raise_exception
      end

      it 'should perform regexp matching and save named captures' do
        @checker.options['conditions'].update(
          'subject' => '\ARe: (?<a>.+)',
          'body' => 'Some (?<b>.+) reply'
        )

        expect { @checker.check }.to change { Event.count }.by(1)
        expect(@checker.notified.sort).to eq([mails.last.message_id])
        expect(@checker.lastseen).to eq(mails.each_with_object(@checker.make_seen) do |mail, seen|
          seen[mail.uidvalidity] = mail.uid
        end)

        expect(Event.last.payload).to eq(expected_payloads.last.update(
                                           'body' => "<div dir=\"ltr\">Some HTML reply<br></div>\n",
                                           'matches' => { 'a' => 'some subject', 'b' => 'HTML' },
                                           'mime_type' => 'text/html'
                                         ))

        expect { @checker.check }.not_to(change { Event.count })
      end

      it 'should narrow mails by has_attachment (true)' do
        @checker.options['conditions']['has_attachment'] = true

        expect { @checker.check }.to change { Event.count }.by(1)

        expect(Event.last.payload['subject']).to eq('Re: some subject')
      end

      it 'should narrow mails by has_attachment (false)' do
        @checker.options['conditions']['has_attachment'] = false

        expect { @checker.check }.to change { Event.count }.by(1)

        expect(Event.last.payload['subject']).to eq('some subject')
      end

      it 'should narrow mail parts by MIME types' do
        @checker.options['mime_types'] = %w[text/plain]
        @checker.options['conditions'].update(
          'subject' => '\ARe: (?<a>.+)',
          'body' => 'Some (?<b>.+) reply'
        )

        expect { @checker.check }.not_to(change { Event.count })
        expect(@checker.notified.sort).to eq([])
        expect(@checker.lastseen).to eq(mails.each_with_object(@checker.make_seen) do |mail, seen|
          seen[mail.uidvalidity] = mail.uid
        end)
      end

      it 'should never mark mails as read unless mark_as_read is true' do
        mails.each do |mail|
          allow(mail).to receive(:mark_as_read).never
        end
        expect { @checker.check }.to change { Event.count }.by(2)
      end

      it 'should mark mails as read if mark_as_read is true' do
        @checker.options['mark_as_read'] = true
        mails.each do |mail|
          allow(mail).to receive(:mark_as_read).once
        end
        expect { @checker.check }.to change { Event.count }.by(2)
      end

      it 'should create just one event for multiple mails with the same Message-Id' do
        mails.first.message_id = mails.last.message_id
        @checker.options['mark_as_read'] = true
        mails.each do |mail|
          allow(mail).to receive(:mark_as_read).once
        end
        expect { @checker.check }.to change { Event.count }.by(1)
      end

      it 'should delete mails if delete is true' do
        @checker.options['delete'] = true
        mails.each do |mail|
          allow(mail).to receive(:delete).once
        end
        expect { @checker.check }.to change { Event.count }.by(2)
      end

      describe 'processing mails with a broken From header value' do
        before do
          # "from" patterns work against mail addresses and not
          # against text parts, so these mails should be skipped if a
          # "from" condition is given.
          #
          # Mail::Header#[]= does not accept an invalid value, so set it directly
          mails.first.header.fields.replace_field Mail::Field.new('from', '.')
          mails.last.header.fields.replace_field Mail::Field.new('from', '@')
        end

        it 'should ignore them without failing if a "from" condition is given' do
          @checker.options['conditions']['from'] = '*'

          expect { @checker.check }.not_to(change { Event.count })
        end
      end

      describe 'with event_headers' do
        let(:expected_headers) do
          [
            {
              'mime_version' => '1.0',
              'x_foo' => "test1-1\ntest1-2"
            },
            {
              'mime_version' => '1.0',
              'x_foo' => "test2-1\ntest2-2"
            }
          ]
        end
        before do
          expected_payloads.zip(expected_headers) do |payload, headers|
            payload['headers'] = headers
          end

          @checker.options['event_headers'] = %w[mime-version x-foo]
          @checker.options['event_headers_style'] = 'snakecased'
          @checker.save!
        end

        it 'should check for mails and emit events with headers' do
          expect { @checker.check }.to change { Event.count }.by(2)
          expect(@checker.notified.sort).to eq(mails.map(&:message_id).sort)
          expect(@checker.lastseen).to eq(mails.each_with_object(@checker.make_seen) do |mail, seen|
                                            seen[mail.uidvalidity] = mail.uid
                                          end)

          expect(Event.last(2).map(&:payload)).to match expected_payloads

          expect { @checker.check }.not_to(change { Event.count })
        end
      end

      describe 'with include_raw_mail' do
        before do
          @checker.options['include_raw_mail'] = true
          @checker.save!
        end

        it 'should check for mails and emit events with raw_mail' do
          expect { @checker.check }.to change { Event.count }.by(2)
          expect(@checker.notified.sort).to eq(mails.map(&:message_id).sort)
          expect(@checker.lastseen).to eq(mails.each_with_object(@checker.make_seen) do |mail, seen|
                                            seen[mail.uidvalidity] = mail.uid
                                          end)

          expect(Event.last(2).map(&:payload)).to match(expected_payloads.map.with_index do |payload, i|
            payload.merge(
              'raw_mail' => satisfy { |d| Base64.decode64(d) == mails[i].encoded }
            )
          end)

          expect { @checker.check }.not_to(change { Event.count })
        end
      end
    end
  end

  describe 'Agents::ImapFolderAgent::Message::Scrubbed' do
    before do
      @class = Class.new do
        def subject
          "broken\xB7subject\xB6"
        end

        def body
          "broken\xB7body\xB6"
        end

        include Agents::ImapFolderAgent::Message::Scrubbed
      end

      @object = @class.new
    end

    describe '#scrubbed' do
      it 'should return a scrubbed string' do
        expect(@object.scrubbed(:subject)).to eq('broken<b7>subject<b6>')
        expect(@object.scrubbed(:body)).to eq('broken<b7>body<b6>')
      end
    end
  end
end
