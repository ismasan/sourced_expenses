# frozen_string_literal: true

RSpec.describe UI::Components::QueueBar do
  def status(**counts)
    WorkQueue::Status.new(queue_name: 'scans', capacity: 3, queued: 0, in_flight: 0, enqueued_total: 0, started_total: 0,
                          released_total: 0, dropped_total: 0, **counts)
  end

  def html(changed: false, **counts) = described_class.new(status(**counts), title: 'Scanning', noun: 'document', changed:).call
  def section(body) = body[/<section[^>]*>/]
  def segments(body, kind) = body.scan("queue-bar__segment--#{kind}").size

  it 'is there but hidden while the queue is idle' do
    body = html

    expect(body).to include('id="queue-scans"', 'hidden')
    expect(segments(body, 'free')).to eq(3)
  end

  it 'shows a segment per document: the slots, striped while in use, then those waiting past a rule' do
    body = html(in_flight: 2, queued: 4)

    expect(body).not_to match(/<section[^>]*hidden/)
    expect(segments(body, 'running')).to eq(2)
    expect(segments(body, 'free')).to eq(1)
    expect(segments(body, 'waiting')).to eq(4)
    expect(body.index('queue-bar__slots')).to be < body.index('queue-bar__waiting')
    expect(body).to include('<strong class="queue-bar__title">Scanning</strong> 2 of 3 slots in use · 4 documents waiting')
  end

  it 'leaves the waiting out with none waiting' do
    body = html(in_flight: 1)

    expect(body).to include('1 of 3 slots in use<')
    expect(body).not_to include('queue-bar__waiting')
  end

  it 'shows the waiting past MAX_SEGMENTS as a count' do
    body = html(capacity: 8, in_flight: 8, queued: 100)

    expect(segments(body, 'running')).to eq(8)
    expect(segments(body, 'waiting')).to eq(described_class::MAX_SEGMENTS - 8)
    expect(body).to include('>+60<', '100 documents waiting')
  end

  describe 'when the queue has just finished' do
    it 'shows all done, its slots done, to slide out (the --done class)' do
      body = html(changed: true)

      expect(section(body)).to include('queue-bar queue-bar--done')
      expect(section(body)).not_to include('hidden')
      expect(body).to include('✓ All done')
      expect(segments(body, 'done')).to eq(3)
      expect(segments(body, 'free') + segments(body, 'running')).to eq(0)
    end

    it 'is just hidden when idle otherwise, as on a page load' do
      expect(section(html)).to include('hidden')
      expect(section(html)).not_to include('--done')
    end

    it 'is busy as ever when the change leaves work to do' do
      body = html(changed: true, in_flight: 1, queued: 2)

      expect(section(body)).not_to include('--done', 'hidden')
      expect(body).to include('1 of 3 slots in use · 2 documents waiting')
    end
  end
end
