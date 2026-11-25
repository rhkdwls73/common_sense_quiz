// 상식 1000제 응시 통계 공통 코드 (config.js 다음에 불러옵니다)
(function () {
  "use strict";
  var cfg = window.QUIZ_STATS || {};
  var url = String(cfg.url || "").replace(/\/+$/, "");
  var key = String(cfg.key || "");

  function call(fn, body) {
    var headers = { "apikey": key, "Content-Type": "application/json" };
    // 예전 형식(anon JWT) 키는 Authorization에도 같은 값을 넣어 줍니다.
    if (key.indexOf("eyJ") === 0) headers["Authorization"] = "Bearer " + key;
    return fetch(url + "/rest/v1/rpc/" + fn, {
      method: "POST", headers: headers, body: JSON.stringify(body || {})
    }).then(function (r) {
      return r.text().then(function (t) {
        var data = null; try { data = t ? JSON.parse(t) : null; } catch (e) {}
        if (!r.ok) throw new Error((data && data.message) || ("서버 응답 " + r.status));
        return data;
      });
    });
  }

  // dist[k] = k점 받은 응시 수 (k = 0~20)
  function rank(dist, score) {
    var total = 0, better = 0;
    for (var k = 0; k < dist.length; k++) { total += dist[k]; if (k > score) better += dist[k]; }
    var tie = dist[score] || 0;
    return { total: total, rank: better + 1, tie: tie, top: total ? (better + 1) / total * 100 : 100 };
  }

  function fmtTop(p) { return p < 10 ? (Math.max(p, 0.1)).toFixed(1) : String(Math.round(p)); }

  // 막대그래프(0~20점) 그리기. mine이 있으면 그 막대를 강조합니다.
  function histogram(box, dist, mine) {
    box.textContent = "";
    var max = Math.max.apply(null, dist.concat([1]));
    var bars = document.createElement("div"); bars.className = "hist-bars";
    var axis = document.createElement("div"); axis.className = "hist-axis";
    dist.forEach(function (n, k) {
      var col = document.createElement("div");
      col.className = "hist-col" + (k === mine ? " me" : "");
      col.title = k + "점: " + n.toLocaleString("ko-KR") + "회";
      var h = n ? Math.max(3, n / max * 82) : 0;
      var cnt = document.createElement("span"); cnt.className = "hist-n"; cnt.textContent = n ? n.toLocaleString("ko-KR") : "";
      cnt.style.bottom = "calc(" + h + "% + 2px)";
      var bar = document.createElement("span"); bar.className = "hist-bar";
      bar.style.height = h + "%";
      col.appendChild(cnt); col.appendChild(bar); bars.appendChild(col);
      var lab = document.createElement("span");
      lab.textContent = (k % 5 === 0 || k === mine) ? String(k) : "";
      if (k === mine) lab.className = "me";
      axis.appendChild(lab);
    });
    box.appendChild(bars); box.appendChild(axis);
  }

  // 문항 키: 문제·정답·오답 내용으로 만든 8자리 해시 (FNV-1a 32비트).
  // 문제나 보기를 고치면 키가 바뀌어 그 문항의 정답률은 새로 집계됩니다.
  function qkey(row) {
    var s = [row[1], row[2], row[3], row[4], row[5]].join("\u241F"), h = 0x811c9dc5;
    for (var i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = (h + ((h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24))) >>> 0;
    }
    return ("0000000" + h.toString(16)).slice(-8);
  }

  // n = [정답, 오답1, 오답2, 오답3]을 고른 수 → 응답 수와 정답률(%)
  function rate(n) {
    var t = (n || []).reduce(function (a, b) { return a + (b || 0); }, 0);
    return { total: t, pct: t ? n[0] / t * 100 : null };
  }

  function fmtSec(v) { return Number(v).toFixed(1) + "초"; }

  // 랭킹전 순위표: list = [{rank, nickname, score, seconds, day?}], opts = {size, me, showDay}
  function leaderboard(box, list, opts) {
    opts = opts || {};
    box.textContent = "";
    if (!list || !list.length) {
      var p = document.createElement("p"); p.className = "hint"; p.textContent = opts.empty || "아직 기록이 없습니다.";
      box.appendChild(p); return;
    }
    var ol = document.createElement("ol"); ol.className = "lb";
    list.forEach(function (r) {
      var li = document.createElement("li");
      if (r.rank <= 3) li.className = "top" + r.rank;
      if (opts.me && r.nickname === opts.me.nickname && r.score === opts.me.score && Number(r.seconds) === Number(opts.me.seconds)) li.className += " me";
      function sp(cls, t) { var e = document.createElement("span"); e.className = cls; e.textContent = t; li.appendChild(e); }
      sp("rk", r.rank + "위");
      sp("nm", r.nickname);
      if (opts.showDay && r.day) sp("dy", String(r.day).slice(5).replace("-", "."));
      sp("sc", r.score + " / " + (opts.size || "?"));
      sp("tm", fmtSec(r.seconds));
      ol.appendChild(li);
    });
    box.appendChild(ol);
  }

  window.QuizStats = {
    enabled: !!(url && key),
    stats: function () { return call("score_stats"); },
    // 판 단위 기록: 시작할 때 판 번호를 받고, 답마다 그 판에 저장, 끝나면 서버가 점수를 계산
    startRound: function (keys) { return call("start_round", { p_keys: keys }).then(function (r) { return r && r.id; }); },
    endRound: function (round, quit) { return call("end_round", { p_round: round, p_quit: !!quit }); },
    rank: rank,
    leaderboard: leaderboard,
    fmtSec: fmtSec,
    rankedStart: function (size, nick, device, keys) {
      return call("ranked_start", { p_size: size, p_nickname: nick, p_device: device, p_keys: keys });
    },
    rankedAnswer: function (round, pos, choice) { return call("ranked_answer", { p_round: round, p_pos: pos, p_choice: choice }); },
    rankedEnd: function (round) { return call("ranked_end", { p_round: round }); },
    rankedBoard: function (size) { return call("ranked_board", { p_size: size }); },
    rankedStatus: function (device) { return call("ranked_status", { p_device: device }); },
    fmtTop: fmtTop,
    histogram: histogram,
    qkey: qkey,
    rate: rate,
    answer: function (key, choice, round, pos) {
      var body = { p_key: key, p_choice: choice };
      if (round) { body.p_round = round; body.p_pos = pos; }
      return call("record_answer", body);
    },
    questionStats: function () { return call("question_stats_all"); },
    rankOf: function (score, seconds, abandoned) {
      return call("score_rank", { p_score: score, p_seconds: seconds, p_abandoned: !!abandoned });
    }
  };
})();
