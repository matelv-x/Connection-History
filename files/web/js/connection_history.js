function poll_success(singleShot, data){
  hideOfflineModal();
  is_online = true;
  poll_delay = poll_delay_default;

  if (!singleShot){
    setTimeout(function(){doPoll(false);}, poll_delay);
  }
}

function updateConnectionHistory(){
  $.get('/stargate/get/dialing_history')
    .done(function(data) {
      const events = data.history || [];
      const summary = data.summary || {};
      $('#connection_history_summary').html(buildSummaryHtml(events, summary));
      $('#connection_history_rows').html('');

      if (events.length === 0) {
        $('#connection_history_rows').append(
          '<tr><td colspan="8">Detailed connection history has not been recorded yet. Lifetime totals are shown above.</td></tr>'
        );
        return;
      }

      $.each(events, function(index, event) {
        $('#connection_history_rows').append(
          '<tr>' +
            '<td>' + escapeHtml(formatTime(event.start_time)) + '</td>' +
            '<td>' + escapeHtml(event.activity || '') + '</td>' +
            '<td>' + escapeHtml(event.status || '') + '</td>' +
            '<td>' + escapeHtml(event.gate_name || '') + '</td>' +
            '<td>' + escapeHtml(event.gate_type || '') + '</td>' +
            '<td>' + escapeHtml(formatAddress(event.gate_address)) + '</td>' +
            '<td>' + escapeHtml(event.source_ip || '') + '</td>' +
            '<td>' + escapeHtml(formatDuration(event.mins)) + '</td>' +
          '</tr>'
        );
      });
    })
    .fail(function() {
      $('#connection_history_summary').html('<p>Unable to load connection history.</p>');
      $('#connection_history_rows').html(
        '<tr><td colspan="8">Unable to load connection history.</td></tr>'
      );
    });
}


function buildSummaryHtml(events, summary) {
  const totalConnections = numberValue(summary.established_fan_count) +
    numberValue(summary.established_standard_count) +
    numberValue(summary.inbound_count);
  const totalMinutes = numberValue(summary.established_fan_mins) +
    numberValue(summary.established_standard_mins) +
    numberValue(summary.inbound_mins);

  return '' +
    '<p>Showing ' + events.length + ' detailed connection event(s).</p>' +
    '<div class="connection-history-lifetime">' +
      '<strong>Lifetime totals:</strong> ' +
      'Connections: ' + totalConnections + ' | ' +
      'Inbound: ' + numberValue(summary.inbound_count) + ' | ' +
      'Outbound fan: ' + numberValue(summary.established_fan_count) + ' | ' +
      'Outbound standard: ' + numberValue(summary.established_standard_count) + ' | ' +
      'Failures: ' + numberValue(summary.dialing_failures) + ' | ' +
      'Open time: ' + formatDuration(totalMinutes) +
    '</div>';
}

function numberValue(value) {
  const number = parseFloat(value);
  return isFinite(number) ? number : 0;
}

function formatAddress(value) {
  if ($.isArray(value)) {
    return value.join('-');
  }
  if (value === null || typeof value === 'undefined') {
    return '';
  }
  return String(value);
}

function formatDuration(value) {
  const mins = parseFloat(value);
  if (!isFinite(mins) || mins <= 0) {
    return '';
  }
  if (mins < 1) {
    return Math.round(mins * 60) + 's';
  }
  return mins.toFixed(1) + ' min';
}

function formatTime(value) {
  if (!value) return '';
  const date = new Date(value);
  if (isNaN(date.getTime())) return value;
  return date.toLocaleString();
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}
