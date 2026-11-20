# frozen_string_literal: true

RSpec.describe UI::Components::QueueStatus do
  def status(**counts)
    Queuer::Status.new(queue_name: 'scans', capacity: 3, queued: 0, in_flight: 0, enqueued_total: 0, started_total: 0,
                       released_total: 0, dropped_total: 0, updated_at: nil, **counts)
  end

  def html(**counts) = described_class.new(status(**counts), title: 'Scanning', noun: 'scan').call

  it 'shows an idle queue as empty slots, and the room it has' do
    body = html

    expect(body).to include('id="queue-scans"', '>Scanning</h2>', 'Idle: room for 3 scans at once')
    expect(body.scan('queue-status__slot"').size).to eq(3)
    expect(body).not_to include('queue-status--busy', 'queue-status__slot--busy', 'done')
  end

  it 'stripes a slot per item in flight, and counts those waiting and done' do
    body = html(in_flight: 2, queued: 5, released_total: 1)

    expect(body).to include('queue-status--busy', '2 of 3 running · 5 waiting', '1 scan done',
                            'aria-label="2 of 3 slots in use"')
    expect(body.scan('queue-status__slot queue-status__slot--busy').size).to eq(2)
  end

  it 'leaves the waiting count out with none waiting' do
    expect(html(in_flight: 1)).to include('1 of 3 running<')
  end

  it 'shows many slots as one bar, filled to the share in use' do
    body = described_class.new(status(capacity: 20, in_flight: 5), title: 'Scanning', noun: 'scan').call

    expect(body).to include('queue-status__bar', 'style="width: 25%"', 'aria-label="5 of 20 slots in use"')
    expect(body).not_to include('queue-status__slot')
  end
end
