// 알쓸신잡 응시 통계 공통 코드 (config.js 다음에 불러옵니다)
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

  // n = [맞힌 수, 틀린 수] → 응답 수와 정답률(%)
  function rate(n) {
    var t = (n || []).reduce(function (a, b) { return a + (b || 0); }, 0);
    return { total: t, pct: t ? n[0] / t * 100 : null };
  }
  // 답을 고른 뒤 서버가 준 보기별 선택 수(공개 보기 순서)와 정답 위치 → 응답 수와 정답률
  function rateOf(n, correct) {
    var t = (n || []).reduce(function (a, b) { return a + (b || 0); }, 0);
    return { total: t, pct: t ? (n[correct] || 0) / t * 100 : null };
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
    // 정답은 서버에만 있습니다: 답(공개 보기 번호)을 보내면 서버가 채점하고 정답·해설을 돌려줌
    startRound: function (qids) { return call("quiz_start", { p_qids: qids }).then(function (r) { return r && r.id; }); },
    endRound: function (round, quit) { return call("end_round", { p_round: round, p_quit: !!quit }); },
    rank: rank,
    leaderboard: leaderboard,
    fmtSec: fmtSec,
    rankedStart: function (size, nick, device) {        // 문제는 서버가 뽑음
      return call("ranked_begin", { p_size: size, p_nickname: nick, p_device: device });
    },
    rankedAnswer: function (round, pos, choice) { return call("ranked_pick", { p_round: round, p_pos: pos, p_choice: choice }); },
    rankedEnd: function (round) { return call("ranked_end", { p_round: round }); },
    rankedBoard: function (size, limit) {
      var body = { p_size: size }; if (limit) body.p_limit = limit;
      return call("ranked_board", body);
    },
    rankedStatus: function (device) { return call("ranked_status", { p_device: device }); },
    fmtTop: fmtTop,
    histogram: histogram,
    rate: rate,
    rateOf: rateOf,
    answer: function (qid, choice, round, pos, practice) {
      var body = { p_qid: qid, p_choice: choice };
      if (round) { body.p_round = round; body.p_pos = pos; }
      if (practice) body.p_practice = true;
      return call("quiz_answer", body);
    },
    questionStats: function () { return call("quiz_rates"); },   // {qid: [맞힌 수, 틀린 수]}
    rankOf: function (score, seconds, abandoned) {
      return call("score_rank", { p_score: score, p_seconds: seconds, p_abandoned: !!abandoned });
    }
  };
})();
