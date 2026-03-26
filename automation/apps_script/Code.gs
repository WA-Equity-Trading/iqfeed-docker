/**
 * IQFeed Ingestion Automation — Google Apps Script
 *
 * Bound to the Google Sheet:
 *   https://docs.google.com/spreadsheets/d/1Do9upOObzy9TN_MtgIa9u6aVXFbVPFYYi6eeBnM0ktI
 *
 * Sheet columns (gid=2109006899):
 *   D = file_ID (job_id)
 *   E = status_code (0=pending, 1=done, 2=in-progress)
 *   G = Start Date (YYYYMMDD)
 *   H = End Date (YYYYMMDD)
 *
 * Setup:
 *   1. Open the Sheet → Extensions → Apps Script
 *   2. Paste this code into Code.gs
 *   3. Paste appsscript.json into the manifest (View → Show manifest)
 *   4. Set up two time-driven triggers (Edit → Current project's triggers):
 *      - checkPendingJobs   → every 5 minutes
 *      - checkCompletedJobs → every 5 minutes
 *   5. On first run, authorize the OAuth scopes
 */

// ── Config ──────────────────────────────────────────────────────────────────
var CONFIG = {
  SHEET_GID:   2109006899,
  BUCKET:      "bkt-prd-iqfeed-raw-files-001",
  JOBS_PREFIX: "jobs/pending/",
  DATA_PREFIX: "raw/market-data/",
  HEADER_ROWS: 1,           // rows to skip at top
  COL_JOB_ID:      4,       // column D (1-based)
  COL_STATUS:      5,       // column E
  COL_START_DATE:  7,       // column G
  COL_END_DATE:    8,       // column H
  STATUS_PENDING:     0,
  STATUS_DONE:        1,
  STATUS_IN_PROGRESS: 2,
};

// ── Entry Points (set these as time-driven triggers) ────────────────────────

/**
 * Polls the Sheet for rows with status_code=0.
 * If outside market hours, writes job JSONs to GCS and sets status_code=2.
 */
function checkPendingJobs() {
  if (isDuringMarketHours_()) {
    Logger.log("Market hours — skipping.");
    return;
  }

  var sheet  = getTargetSheet_();
  var data   = sheet.getDataRange().getValues();
  var token  = getGcsToken_();
  var queued = 0;

  for (var i = CONFIG.HEADER_ROWS; i < data.length; i++) {
    var row       = data[i];
    var jobId     = String(row[CONFIG.COL_JOB_ID - 1]).trim();
    var status    = Number(row[CONFIG.COL_STATUS - 1]);
    var startDate = String(row[CONFIG.COL_START_DATE - 1]).trim();
    var endDate   = String(row[CONFIG.COL_END_DATE - 1]).trim();

    if (status !== CONFIG.STATUS_PENDING) continue;
    if (!jobId || !startDate || !endDate) continue;

    // Write job JSON to GCS
    var job = {
      job_id:     jobId,
      start_date: startDate,
      end_date:   endDate,
      output_path: CONFIG.DATA_PREFIX + jobId,
      created_at: new Date().toISOString(),
    };

    var objectName = CONFIG.JOBS_PREFIX + jobId + ".json";
    uploadToGcs_(token, CONFIG.BUCKET, objectName, JSON.stringify(job));

    // Set status_code = 2 (in-progress)
    var statusCell = sheet.getRange(i + 1, CONFIG.COL_STATUS);
    statusCell.setValue(CONFIG.STATUS_IN_PROGRESS);

    queued++;
    Logger.log("Queued job: " + jobId + " (" + startDate + " → " + endDate + ")");
  }

  Logger.log("Queued " + queued + " job(s).");
}

/**
 * Polls GCS for _SUCCESS files corresponding to in-progress rows.
 * When found, sets status_code=1.
 */
function checkCompletedJobs() {
  var sheet = getTargetSheet_();
  var data  = sheet.getDataRange().getValues();
  var token = getGcsToken_();
  var completed = 0;

  for (var i = CONFIG.HEADER_ROWS; i < data.length; i++) {
    var row    = data[i];
    var jobId  = String(row[CONFIG.COL_JOB_ID - 1]).trim();
    var status = Number(row[CONFIG.COL_STATUS - 1]);

    if (status !== CONFIG.STATUS_IN_PROGRESS) continue;
    if (!jobId) continue;

    // Check if _SUCCESS exists under any date subfolder
    var prefix = CONFIG.DATA_PREFIX + jobId + "/";
    var objects = listGcsObjects_(token, CONFIG.BUCKET, prefix);

    var hasSuccess = objects.some(function(name) {
      return name.endsWith("/_SUCCESS");
    });

    if (hasSuccess) {
      var statusCell = sheet.getRange(i + 1, CONFIG.COL_STATUS);
      statusCell.setValue(CONFIG.STATUS_DONE);

      // Clean up the pending job file from GCS (if still there)
      var jobFile = CONFIG.JOBS_PREFIX + jobId + ".json";
      deleteGcsObject_(token, CONFIG.BUCKET, jobFile);

      completed++;
      Logger.log("Completed: " + jobId);
    }
  }

  Logger.log("Marked " + completed + " job(s) as done.");
}

// ── Market Hours Check ──────────────────────────────────────────────────────

/**
 * Returns true if current time is during US market hours (9:30 AM – 4:00 PM ET).
 * Also returns true on weekends (no trading).
 */
function isDuringMarketHours_() {
  var now = new Date();

  // Convert to ET (America/New_York)
  var etString = Utilities.formatDate(now, "America/New_York", "EEE,HH,mm");
  var parts    = etString.split(",");
  var dayOfWeek = parts[0];
  var hour      = parseInt(parts[1], 10);
  var minute    = parseInt(parts[2], 10);

  // Weekends — don't block (allow downloads on weekends)
  if (dayOfWeek === "Sat" || dayOfWeek === "Sun") return false;

  var timeMinutes = hour * 60 + minute;
  var marketOpen  = 9 * 60 + 30;   // 9:30 AM ET
  var marketClose = 16 * 60;       // 4:00 PM ET

  return timeMinutes >= marketOpen && timeMinutes < marketClose;
}

// ── Sheet Helpers ───────────────────────────────────────────────────────────

function getTargetSheet_() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheets = ss.getSheets();

  for (var i = 0; i < sheets.length; i++) {
    if (sheets[i].getSheetId() === CONFIG.SHEET_GID) {
      return sheets[i];
    }
  }
  throw new Error("Sheet with gid=" + CONFIG.SHEET_GID + " not found.");
}

// ── GCS Helpers (JSON API via UrlFetchApp) ──────────────────────────────────

function getGcsToken_() {
  return ScriptApp.getOAuthToken();
}

/**
 * Upload a string as a GCS object.
 */
function uploadToGcs_(token, bucket, objectName, content) {
  var url = "https://storage.googleapis.com/upload/storage/v1/b/"
    + encodeURIComponent(bucket)
    + "/o?uploadType=media&name=" + encodeURIComponent(objectName);

  UrlFetchApp.fetch(url, {
    method:  "POST",
    headers: { "Authorization": "Bearer " + token },
    contentType: "application/json",
    payload: content,
    muteHttpExceptions: true,
  });
}

/**
 * List objects under a prefix. Returns array of object names.
 */
function listGcsObjects_(token, bucket, prefix) {
  var url = "https://storage.googleapis.com/storage/v1/b/"
    + encodeURIComponent(bucket)
    + "/o?prefix=" + encodeURIComponent(prefix)
    + "&fields=items/name";

  var resp = UrlFetchApp.fetch(url, {
    method:  "GET",
    headers: { "Authorization": "Bearer " + token },
    muteHttpExceptions: true,
  });

  var json = JSON.parse(resp.getContentText());
  if (!json.items) return [];
  return json.items.map(function(item) { return item.name; });
}

/**
 * Delete a GCS object (best-effort, ignores 404).
 */
function deleteGcsObject_(token, bucket, objectName) {
  var url = "https://storage.googleapis.com/storage/v1/b/"
    + encodeURIComponent(bucket)
    + "/o/" + encodeURIComponent(objectName);

  UrlFetchApp.fetch(url, {
    method:  "DELETE",
    headers: { "Authorization": "Bearer " + token },
    muteHttpExceptions: true,
  });
}
