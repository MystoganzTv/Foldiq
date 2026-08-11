function escapeCSVCell(value) {
  let text = value == null ? '' : String(value);
  if (/^[\t\r ]*[=+\-@]/.test(text)) text = `'${text}`;
  return `"${text.replaceAll('"', '""')}"`;
}

function rowsToCSV(rows) {
  return rows.map(row => {
    const values = row && typeof row === 'object' ? Object.values(row) : [row];
    return values.map(escapeCSVCell).join(',');
  }).join('\r\n');
}

module.exports = { escapeCSVCell, rowsToCSV };
