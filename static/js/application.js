/* Single state for forms, tables and charts. All user values use textContent. */
(() => {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const page = document.body.dataset.page;
  const titles = {
    dashboard: "Tổng quan môi trường",
    farms: "Nhà yến",
    areas: "Khu vực & ngưỡng",
    devices: "Thiết bị",
    sensors: "Dữ liệu cảm biến",
    alerts: "Cảnh báo",
    birds: "Lượt chim ra / vào",
    analytics: "Báo cáo tương quan",
    events: "Sự kiện mô phỏng",
    controls: "Điều khiển mô phỏng",
  };
  const configs = {
    farms: {
      id: "HouseId",
      name: "HouseName",
      columns: [
        ["HouseId", "Mã"],
        ["HouseName", "Nhà yến"],
        ["ManagerName", "Quản lý"],
        ["Status", "Trạng thái"],
        ["ZoneCount", "Số khu vực"],
        ["DeviceCount", "Số thiết bị"],
        ["OpenAlertCount", "Cảnh báo đang mở"],
        ["WarningZoneCount", "Khu vực vượt ngưỡng"],
        ["OverallStatus", "Tổng quan"],
      ],
    },
    areas: {
      id: "ZoneId",
      name: "ZoneName",
      columns: [
        ["ZoneId", "Mã"],
        ["ZoneName", "Khu vực"],
        ["HouseId", "Nhà yến"],
        ["Description", "Mô tả"],
        ["Status", "Trạng thái"],
      ],
    },
    devices: {
      id: "DeviceId",
      name: "DeviceName",
      columns: [
        ["DeviceId", "Mã"],
        ["DeviceName", "Thiết bị"],
        ["ZoneId", "Khu vực"],
        ["DeviceType", "Loại"],
        ["Status", "Trạng thái"],
      ],
    },
  };
  let csrf = "",
    user = null,
    items = [],
    pageNo = 1,
    total = 0,
    editing = null,
    selectedZone = null,
    rowVersion = null,
    busy = false;
  let houses = [],
    zones = [],
    devices = [],
    managers = [];
  const size = 50;
  // Debounce o tim kiem: go tiep thi huy hen cu, chi goi load() sau 300ms.
  let searchTimer = null;
  function message(text, error = false) {
    $("message").textContent = text;
    $("message").classList.toggle("error", error);
  }
  async function api(path, method = "GET", body) {
    const response = await fetch("/api" + path, {
      method,
      headers: {
        Accept: "application/json",
        ...(body ? { "Content-Type": "application/json" } : {}),
        ...(method !== "GET" ? { "X-CSRF-Token": csrf } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    let result;
    try {
      result = await response.json();
    } catch {
      throw new Error("Phản hồi không hợp lệ.");
    }
    if (!response.ok || result.success !== true)
      throw new Error(
        `${result.message || "Thao tác thất bại"} (${result.code || response.status})`,
      );
    return result.data;
  }
  function node(tag, text, className) {
    const n = document.createElement(tag);
    if (text !== undefined) n.textContent = text;
    if (className) n.className = className;
    return n;
  }
  function button(text, fn, cls = "secondary") {
    const b = node("button", text, cls);
    b.type = "button";
    b.addEventListener("click", async () => {
      b.disabled = true;
      try {
        await fn();
      } catch (e) {
        message(e.message, true);
      } finally {
        b.disabled = false;
      }
    });
    return b;
  }
  const labels = {
    ACTIVE: "Đang hoạt động",
    INACTIVE: "Ngừng hoạt động",
    MAINTENANCE: "Bảo trì",
    SENSOR: "Cảm biến",
    FAN: "Quạt",
    HUMIDIFIER: "Máy tạo ẩm",
    LIGHT: "Đèn",
    NORMAL: "Bình thường",
    WARNING: "Vượt ngưỡng",
    UNCONFIGURED: "Chưa cấu hình ngưỡng",
    NO_DATA: "Chưa có dữ liệu",
    INCOMPLETE_DATA: "Thiếu số đo",
    PENDING: "Chờ xử lý",
    ACKNOWLEDGED: "Đã xác nhận",
    RESOLVED: "Đã xử lý",
    NEW: "Mới",
    AUTO: "Tự động",
    MANUAL: "Thủ công",
  };
  function value(v, key = "") {
    if (v === null || v === undefined) return "Chưa có dữ liệu";
    if (typeof v === "boolean") return v ? "Bật" : "Tắt";
    if (/At$|Date$|updated|RecordedAt/.test(key))
      return new Date(v).toLocaleString("vi-VN");
    return labels[v] || String(v);
  }
  function field(form, key, label, options = {}) {
    const wrap = node("label", label);
    let input;
    if (options.choices) {
      input = document.createElement("select");
      for (const [v, t] of options.choices) {
        const option = node("option", t);
        option.value = v;
        input.append(option);
      }
    } else {
      input = document.createElement("input");
      input.type = options.type || "text";
      if (options.max) input.maxLength = options.max;
    }
    input.name = key;
    input.id = "field-" + key;
    input.required = options.required !== false;
    if (options.type === "number") {
      input.min = options.min ?? 1;
      input.step = options.step || "1";
      if (options.maxValue !== undefined) input.max = options.maxValue;
    }
    wrap.append(input);
    form.append(wrap);
    return input;
  }
  function selectChoices(rows, id, label) {
    return rows.map((r) => [r[id], `${r[label]} (#${r[id]})`]);
  }
  async function all(entity) {
    let result = [],
      p = 1;
    while (true) {
      const d = await api(`/${entity}?limit=1000&page=${p++}`);
      result.push(...d.items);
      if (result.length >= d.total) return result;
    }
  }
  async function lookups() {
    [houses, zones, devices] = await Promise.all(
      ["farms", "areas", "devices"].map(all),
    );
    if (user.Role === "ADMIN") managers = await api("/managers");
  }
  function editor() {
    if (!configs[page] || user.Role !== "ADMIN") return;
    $("editor").hidden = false;
    const form = $("entityForm");
    form.replaceChildren();
    field(form, "name", "Tên", { max: 100 });
    if (page === "farms") {
      field(form, "address", "Địa chỉ", { required: false, max: 255 });
      field(form, "manager_id", "Người quản lý", {
        choices: selectChoices(managers, "UserID", "FullName"),
      });
    }
    if (page === "areas") {
      field(form, "house_id", "Nhà yến", {
        choices: selectChoices(houses, "HouseId", "HouseName"),
      });
      field(form, "description", "Mô tả", { required: false, max: 255 });
    }
    if (page === "devices") {
      field(form, "zone_id", "Khu vực", {
        choices: selectChoices(zones, "ZoneId", "ZoneName"),
      });
      field(form, "device_type", "Loại thiết bị", {
        choices: ["SENSOR", "FAN", "HUMIDIFIER", "LIGHT"].map((v) => [
          v,
          labels[v],
        ]),
      });
    }
    field(form, "status", "Trạng thái", {
      choices: (page === "devices"
        ? ["ACTIVE", "INACTIVE", "MAINTENANCE"]
        : ["ACTIVE", "INACTIVE"]
      ).map((v) => [v, labels[v]]),
    });
    const submit = node("button", "Lưu");
    submit.type = "submit";
    form.append(
      submit,
      button("Hủy chỉnh sửa", () => resetEditor()),
    );
    form.onsubmit = async (e) => {
      e.preventDefault();
      submit.disabled = true;
      try {
        const data = Object.fromEntries(new FormData(form));
        data.name = (data.name || "").trim();
        if (!data.name) {
          message("Tên không được để trống.", true);
          return;
        }
        for (const key of ["manager_id", "house_id", "zone_id"])
          if (key in data) data[key] = Number(data[key]);
        const pickMessage = {
          manager_id: "Chọn người quản lý.",
          house_id: "Chọn nhà yến.",
          zone_id: "Chọn khu vực.",
        };
        for (const [key, msg] of Object.entries(pickMessage))
          if (
            key in data &&
            (!Number.isInteger(data[key]) || data[key] <= 0)
          ) {
            message(msg, true);
            return;
          }
        await api(
          `/${page}${editing ? "/" + editing : ""}`,
          editing ? "PUT" : "POST",
          data,
        );
        resetEditor();
        await lookups();
        await load();
        message("Đã lưu vào cơ sở dữ liệu.");
      } catch (err) {
        message(err.message, true);
      } finally {
        submit.disabled = false;
      }
    };
  }
  function resetEditor() {
    editing = null;
    $("entityForm").reset();
    $("editorTitle").textContent = "Thêm mới";
  }
  function edit(row) {
    editing = row[configs[page].id];
    const f = $("entityForm");
    const data = {
      name: row[configs[page].name],
      address: row.Address,
      manager_id: row.ManagerId,
      house_id: row.HouseId,
      description: row.Description,
      zone_id: row.ZoneId,
      device_type: row.DeviceType,
      status: row.Status,
    };
    for (const [k, v] of Object.entries(data))
      if (f.elements[k]) f.elements[k].value = v ?? "";
    $("editorTitle").textContent = "Chỉnh sửa #" + editing;
    f.scrollIntoView({ behavior: "smooth", block: "center" });
  }
  function filterSetup() {
    const filters = $("filters");
    filters.hidden = false;
    if (configs[page]) {
      field(filters, "search", "Tìm kiếm", { required: false });
      field(filters, "status", "Trạng thái", {
        choices: [
          ["", "Tất cả"],
          ["ACTIVE", "Đang hoạt động"],
          ["INACTIVE", "Ngừng hoạt động"],
          ...(page === "devices" ? [["MAINTENANCE", "Bảo trì"]] : []),
        ],
      });
      filters.addEventListener("input", () => {
        // Farms loc client-side tren toan bo du lieu da tai; areas/devices
        // goi server (debounce 300ms, ve trang 1).
        if (page === "farms") return renderEntity();
        clearTimeout(searchTimer);
        searchTimer = setTimeout(() => {
          pageNo = 1;
          load();
        }, 300);
      });
      return;
    }
    if (page === "sensors") {
      field(filters, "device_id", "Cảm biến", {
        choices: [
          ["", "Tất cả"],
          ...selectChoices(
            devices.filter((d) => d.DeviceType === "SENSOR"),
            "DeviceId",
            "DeviceName",
          ),
        ],
      });
    }
    if (page === "birds") {
      field(filters, "house_id", "Nhà yến", {
        choices: selectChoices(houses, "HouseId", "HouseName"),
      });
    }
    if (page === "analytics") {
      field(filters, "house_id", "Nhà yến", {
        choices: [
          ["", "Tất cả nhà yến"],
          ...selectChoices(houses, "HouseId", "HouseName"),
        ],
      });
      field(filters, "zone_id", "Khu vực", {
        choices: [
          ["", "Tất cả khu vực"],
          ...selectChoices(zones, "ZoneId", "ZoneName"),
        ],
      });
    }
    if (page === "events") {
      field(filters, "status", "Trạng thái", {
        choices: [
          ["", "Chưa xử lý xong"],
          ["NEW", "Mới"],
          ["ACKNOWLEDGED", "Đã xác nhận"],
          ["RESOLVED", "Đã xử lý"],
        ],
      });
    }
    if (["sensors", "birds", "analytics"].includes(page)) {
      for (const [k, label] of [
        ["from", "Từ"],
        ["to", "Đến (không bao gồm)"],
      ]) {
        const input = field(filters, k, label, { type: "datetime-local" });
        // Báo cáo tương quan mặc định 7 ngày gần nhất; các trang khác 1 ngày.
        const back =
          k === "from" ? (page === "analytics" ? 7 * 86400000 : 86400000) : 0;
        const d = new Date(Date.now() - back);
        input.value = new Date(d - d.getTimezoneOffset() * 60000)
          .toISOString()
          .slice(0, 16);
      }
    }
    if (page === "dashboard") {
      field(filters, "house_id", "Nhà yến", {
        choices: [
          ["", "Tất cả nhà yến"],
          ...selectChoices(houses, "HouseId", "HouseName"),
        ],
      });
    }
    if (["alerts", "controls"].includes(page)) {
      field(filters, "search", "Tìm kiếm", { required: false });
      filters.addEventListener("input", () => {
        clearTimeout(searchTimer);
        searchTimer = setTimeout(() => load(), 300);
      });
      return;
    }
    filters.append(button("Áp dụng", () => load()));
  }
  function params() {
    const p = new URLSearchParams();
    $("filters")
      .querySelectorAll("input,select")
      .forEach((i) => {
        if (i.value)
          p.set(
            i.name,
            ["from", "to"].includes(i.name)
              ? new Date(i.value).toISOString()
              : i.value,
          );
      });
    return p;
  }
  function table(columns, records, actions) {
    const head = node("tr");
    columns.forEach(([, label]) => head.append(node("th", label)));
    if (actions) head.append(node("th", "Thao tác"));
    $("tableHead").replaceChildren(head);
    $("tableBody").replaceChildren();
    if (!records.length) {
      const td = node("td", "Chưa có dữ liệu phù hợp.");
      td.colSpan = columns.length + (actions ? 1 : 0);
      const tr = node("tr");
      tr.append(td);
      $("tableBody").append(tr);
    }
    for (const row of records) {
      const tr = node("tr");
      for (const [key] of columns) tr.append(node("td", value(row[key], key)));
      if (actions) {
        const td = node("td");
        actions(row).forEach((b) => td.append(b));
        tr.append(td);
      }
      $("tableBody").append(tr);
    }
    $("count").textContent = `${records.length} dòng đang hiển thị`;
  }
  function renderEntity() {
    const c = configs[page],
      f = $("filters");
    // Farms load toan bo nha tu /farms/overview trong 1 lan goi (khong
    // phan trang) nen loc client-side; areas/devices server da loc.
    let records = items;
    if (page === "farms") {
      const term = (
        f.querySelector("[name=search]").value || ""
      ).toLocaleLowerCase("vi");
      const status = f.querySelector("[name=status]").value;
      records = items.filter(
        (r) =>
          (!status || r.Status === status) &&
          Object.values(r).join(" ").toLocaleLowerCase("vi").includes(term),
      );
    }
    table(c.columns, records, (r) => [
      ...(user.Role === "ADMIN"
        ? [
            button("Sửa", () => edit(r)),
            button(
              "Ngừng hoạt động",
              async () => {
                if (!confirm("Ngừng hoạt động mục này?")) return;
                await api(`/${page}/${r[c.id]}`, "DELETE");
                await lookups();
                await load();
              },
              "danger",
            ),
          ]
        : []),
      ...(page === "areas"
        ? [button("Ngưỡng", () => threshold(r.ZoneId))]
        : []),
    ]);
    $("count").textContent =
      page === "farms"
        ? `Trang ${pageNo} · ${records.length}/${items.length} dòng trang này · tổng ${total}`
        : `Trang ${pageNo} · ${items.length} dòng trang này · tổng ${total}`;
  }
  async function threshold(zoneId) {
    selectedZone = zoneId;
    const rows = await api("/thresholds/" + zoneId);
    if (selectedZone !== zoneId) return;
    const row = rows[0];
    if (row?.Success === false) throw new Error(row.Message);
    rowVersion = row?.RowVer || null;
    const form = $("thresholdForm");
    form.replaceChildren();
    $("thresholdEditor").hidden = false;
    for (const [k, label, min, max, required] of [
      ["MinTemperature", "Nhiệt độ tối thiểu", -40, 100, true],
      ["MaxTemperature", "Nhiệt độ tối đa", -40, 100, true],
      ["MinHumidity", "Độ ẩm tối thiểu", 0, 100, true],
      ["MaxHumidity", "Độ ẩm tối đa", 0, 100, true],
      // Ngưỡng ánh sáng (lux) cho quy tắc LIGHT AUTO: bỏ trống cả hai ô
      // nghĩa là khu vực chưa cấu hình ngưỡng sáng.
      ["MinLightLux", "Ánh sáng tối thiểu (lux)", 0, 200000, false],
      ["MaxLightLux", "Ánh sáng tối đa (lux)", 0, 200000, false],
    ]) {
      const i = field(form, k, label, {
        type: "number",
        min,
        maxValue: max,
        step: "0.01",
        required,
      });
      i.value = row?.[k] ?? "";
      i.disabled = user.Role !== "ADMIN";
    }
    if (user.Role === "ADMIN") {
      const save = node("button", "Lưu ngưỡng");
      save.type = "submit";
      form.append(save);
      form.onsubmit = async (e) => {
        e.preventDefault();
        save.disabled = true;
        try {
          // Ô trống phải gửi null (bỏ hẳn khỏi payload) chứ không phải
          // Number("") = 0, để "chưa cấu hình" không thành ngưỡng 0 lux.
          const data = Object.fromEntries(
            [...new FormData(form)]
              .filter(([, v]) => v !== "")
              .map(([k, v]) => [k, Number(v)]),
          );
          // Kiem tra client-side truoc khi goi API (cung cau chu nhu server).
          const hasMinLux = data.MinLightLux !== undefined;
          const hasMaxLux = data.MaxLightLux !== undefined;
          if (hasMinLux !== hasMaxLux) {
            message(
              "Cần gửi cả MinLightLux và MaxLightLux, hoặc bỏ trống cả hai.",
              true,
            );
            return;
          }
          if (
            (data.MinTemperature !== undefined &&
              data.MaxTemperature !== undefined &&
              data.MinTemperature > data.MaxTemperature) ||
            (data.MinHumidity !== undefined &&
              data.MaxHumidity !== undefined &&
              data.MinHumidity > data.MaxHumidity)
          ) {
            message("Min phải nhỏ hơn hoặc bằng Max.", true);
            return;
          }
          if (
            hasMinLux &&
            hasMaxLux &&
            data.MinLightLux > data.MaxLightLux
          ) {
            message("MinLightLux phải nhỏ hơn hoặc bằng MaxLightLux.", true);
            return;
          }
          if (rowVersion) data.row_version = rowVersion;
          await api("/thresholds/" + zoneId, rowVersion ? "PUT" : "POST", data);
          await threshold(zoneId);
          message("Đã lưu ngưỡng.");
        } catch (err) {
          message(err.message + " Hãy tải lại ngưỡng nếu có xung đột.", true);
        } finally {
          save.disabled = false;
        }
      };
    }
  }
  function chart() {
    const metric = $("chartMetric").value;
    const points = items
      .filter((r) => typeof r[metric] === "number")
      .slice()
      .sort(
        (a, b) =>
          new Date(a.RecordeAt) - new Date(b.RecordeAt) ||
          Number(a.ReadingId) - Number(b.ReadingId),
      );
    const svg = $("historyChart");
    svg.replaceChildren();
    if (!points.length) {
      $("chartNote").textContent = "Chưa có số đo cho chỉ số này.";
      return;
    }
    const values = points.map((p) => p[metric]),
      low = Math.min(...values),
      high = Math.max(...values),
      span = high - low || 1;
    const groups = new Map();
    points.forEach((p, i) => {
      if (!groups.has(p.DeviceId)) groups.set(p.DeviceId, []);
      groups.get(p.DeviceId).push([i, p]);
    });
    let color = 0;
    const colors = ["#34754d", "#ca8244", "#4c7caf", "#986a9b"];
    for (const [id, group] of groups) {
      const line = document.createElementNS(
        "http://www.w3.org/2000/svg",
        "polyline",
      );
      line.setAttribute(
        "points",
        group
          .map(
            ([i, p]) =>
              `${25 + (i * 850) / Math.max(points.length - 1, 1)},${210 - ((p[metric] - low) * 180) / span}`,
          )
          .join(" "),
      );
      line.setAttribute("fill", "none");
      line.setAttribute("stroke", colors[color++ % colors.length]);
      line.setAttribute("stroke-width", "3");
      const title = document.createElementNS(
        "http://www.w3.org/2000/svg",
        "title",
      );
      title.textContent = "Cảm biến #" + id;
      line.append(title);
      svg.append(line);
    }
    for (let i = 0; i < points.length; i++) {
      const dot = document.createElementNS(
        "http://www.w3.org/2000/svg",
        "circle",
      );
      dot.setAttribute("cx", 25 + (i * 850) / Math.max(points.length - 1, 1));
      dot.setAttribute("cy", 210 - ((points[i][metric] - low) * 180) / span);
      dot.setAttribute("r", "3");
      dot.setAttribute("fill", "#34754d");
      svg.append(dot);
    }
    $("chartNote").textContent =
      `${points.length} số đo · ${low} → ${high} · ${new Date(points[0].RecordeAt).toLocaleString("vi-VN")} → ${new Date(points.at(-1).RecordeAt).toLocaleString("vi-VN")}. Mỗi đường là một cảm biến. Tối đa 1000 số đo mới nhất trong khoảng lọc.`;
  }
  // P4: he so tuong quan Pearson giua hai chuoi so cung do dai.
  // Can toi thieu 3 cap (khop SP: duoi 3 ngay co InRangePct thi
  // PearsonInRangeVsNet la NULL, CorrelationStrength la INSUFFICIENT_DATA).
  function pearson(pairs) {
    if (pairs.length < 3) return null;
    const mx = pairs.reduce((s, p) => s + p[0], 0) / pairs.length;
    const my = pairs.reduce((s, p) => s + p[1], 0) / pairs.length;
    let num = 0,
      dx = 0,
      dy = 0;
    for (const [x, y] of pairs) {
      num += (x - mx) * (y - my);
      dx += (x - mx) ** 2;
      dy += (y - my) ** 2;
    }
    if (!dx || !dy) return null;
    return num / Math.sqrt(dx * dy);
  }
  function correlationNote(text) {
    let note = $("analyticsNote");
    if (!note) {
      note = node("p");
      note.id = "analyticsNote";
      $("tablePanel").prepend(note);
    }
    note.textContent = text;
  }
  // P4: the tong hop + dien giai tuong quan cho trang analytics.
  // Nang suat tam do bang luong chim ra/vao (chua co bang so to thu hoach).
  function renderCorrelation() {
    const num = (r, k) => (typeof r[k] === "number" ? r[k] : null);
    const sum = (k) => items.reduce((s, r) => s + (num(r, k) ?? 0), 0);
    // % trong nguong theo trong so: tong so do trong nguong / tong so do
    // o khu da cau hinh nguong (dung dinh nghia InRangePct cua SP).
    const configured = sum("ConfiguredReadingCount");
    const inRangePct = configured
      ? (sum("InRangeCount") / configured) * 100
      : null;
    const pairs = items
      .map((r) => [num(r, "InRangePct"), num(r, "NetMovement")])
      .filter(([x, y]) => x !== null && y !== null);
    // Uu tien he so SP tinh san theo tung nha (PearsonInRangeVsNet +
    // CorrelationStrength di kem tren moi dong); SP tra INSUFFICIENT_DATA
    // khi duoi 3 ngay co InRangePct. Chi tu tinh o frontend khi SP
    // khong tra hai cot nay.
    const spStrength = items.length ? items[0].CorrelationStrength : null;
    const spR = items.length ? num(items[0], "PearsonInRangeVsNet") : null;
    const r =
      spStrength === "INSUFFICIENT_DATA"
        ? null
        : spR !== null
          ? spR
          : pearson(pairs);
    const enough = pairs.length >= 3 && r !== null;
    $("dashboardSummary").hidden = false;
    $("dashboardSummary").replaceChildren();
    for (const [label, v] of [
      ["Dòng dữ liệu (ngày × nhà yến)", items.length],
      ["Tổng lượt chim vào", sum("BirdInCount")],
      ["Tổng lượt chim ra", sum("BirdOutCount")],
      ["Chênh lệch vào − ra", sum("NetMovement")],
      [
        "Tổng giờ ước tính trong ngưỡng",
        sum("EstimatedHoursInRange").toFixed(1) + " giờ",
      ],
      [
        "% trong ngưỡng (theo trọng số số đo)",
        inRangePct === null ? "Chưa có dữ liệu" : inRangePct.toFixed(1) + " %",
      ],
      [
        "Hệ số tương quan r (% trong ngưỡng ↔ chênh lệch chim)",
        enough ? r.toFixed(2) : "Chưa đủ dữ liệu",
      ],
    ]) {
      const card = node("div", undefined, "stat");
      card.append(node("span", label), node("strong", v));
      $("dashboardSummary").append(card);
    }
    correlationNote(
      !enough
        ? "Chưa đủ dữ liệu để kết luận tương quan: cần ít nhất 3 ngày có % trong ngưỡng (dưới 3 ngày SP trả PearsonInRangeVsNet là NULL và CorrelationStrength là INSUFFICIENT_DATA)."
        : spStrength
          ? `r = ${r.toFixed(2)}: CorrelationStrength = ${spStrength} (SP sp_GetEnvironmentYieldCorrelation tính sẵn theo từng nhà). Đây là tương quan thống kê trên dữ liệu mô phỏng, không phải quan hệ nhân quả.`
          : `r = ${r.toFixed(2)}: tương quan ${Math.abs(r) >= 0.7 ? "mạnh" : Math.abs(r) >= 0.4 ? "trung bình" : "yếu"}, ${r > 0 ? "thuận — nhà/ngày có môi trường trong ngưỡng nhiều hơn có xu hướng chênh lệch chim vào cao hơn" : r < 0 ? "nghịch — % trong ngưỡng cao hơn đi cùng chênh lệch chim vào thấp hơn" : "gần như không có liên hệ tuyến tính"}. Đây là tương quan thống kê trên dữ liệu mô phỏng, không phải quan hệ nhân quả.`,
    );
  }
  async function load() {
    if (busy) return;
    busy = true;
    $("refresh").disabled = true;
    message("Đang tải dữ liệu…");
    try {
      if (page === "farms") {
        const rows = await api("/farms/overview");
        items = rows;
        total = rows.length;
        renderEntity();
      } else if (configs[page]) {
        const d = await api(`/${page}?page=${pageNo}&limit=${size}&${params()}`);
        items = d.items;
        total = d.total;
        renderEntity();
      } else if (page === "dashboard") {
        const d = await api("/dashboard/zones?" + params());
        items = d.zones;
        table(
          [
            ["zone_name", "Khu vực"],
            ["house_name", "Nhà yến"],
            ["temperature", "Nhiệt độ TB (°C)"],
            ["humidity", "Độ ẩm TB (%)"],
            ["reading_sensor_count", "Cảm biến có số đo"],
            ["sensor_count", "Tổng cảm biến"],
            ["status", "Môi trường"],
            ["last_updated", "Số đo mới nhất"],
          ],
          items,
        );
        $("dashboardSummary").hidden = false;
        $("dashboardSummary").replaceChildren();
        for (const [label, v] of [
          ["Khu vực", items.length],
          [
            "Khu vực vượt ngưỡng",
            items.filter((z) => z.status === "WARNING").length,
          ],
          [
            "Cảm biến có số đo",
            items.reduce((n, z) => n + z.reading_sensor_count, 0),
          ],
        ]) {
          const card = node("div", undefined, "stat");
          card.append(node("span", label), node("strong", v));
          $("dashboardSummary").append(card);
        }
      } else if (page === "sensors") {
        items = await api("/metrics?" + params());
        table(
          [
            ["DeviceId", "Cảm biến"],
            ["ReadingId", "Số đo"],
            ["Temperature", "°C"],
            ["Humidity", "% RH"],
            ["CO2Ppm", "CO₂ ppm"],
            ["LightLux", "Ánh sáng lux"],
            ["RecordeAt", "Thời gian"],
          ],
          items,
        );
        $("chartPanel").hidden = false;
        chart();
      } else if (page === "birds") {
        if (!houses.length) throw new Error("Chưa có nhà yến.");
        items = await api("/birds?" + params());
        table(
          [
            ["ObservedDate", "Ngày (giờ Việt Nam)"],
            ["HouseId", "Nhà yến"],
            ["InCount", "Lượt vào"],
            ["OutCount", "Lượt ra"],
            ["EventCount", "Số sự kiện"],
          ],
          items,
        );
      } else if (page === "analytics") {
        const d = await api("/analytics/correlation?" + params());
        items = Array.isArray(d) ? d : d.rows || d.items || [];
        table(
          [
            ["ReportDate", "Ngày"],
            ["HouseName", "Nhà yến"],
            ["ZoneName", "Khu vực"],
            ["ReadingCount", "Số số đo"],
            ["InRangePct", "% trong ngưỡng"],
            ["EstimatedHoursInRange", "Giờ trong ngưỡng (ước tính)"],
            ["AvgTemperature", "Nhiệt độ TB (°C)"],
            ["AvgHumidity", "Độ ẩm TB (%)"],
            ["BirdInCount", "Chim vào"],
            ["BirdOutCount", "Chim ra"],
            ["NetMovement", "Chênh lệch vào − ra"],
          ],
          items,
        );
        renderCorrelation();
      } else if (page === "alerts") {
        items = await api("/alerts?limit=1000&" + params());
        table(
          [
            ["AlertId", "Mã"],
            ["ZoneId", "Khu vực"],
            ["AlertType", "Loại"],
            ["Message", "Nội dung"],
            ["Status", "Trạng thái"],
            ["CreatedAt", "Thời gian"],
          ],
          items,
          (r) => [
            button(
              r.Status === "PENDING"
                ? "Xác nhận"
                : r.Status === "ACKNOWLEDGED"
                  ? "Đã xử lý"
                  : "Mở lại",
              async () => {
                await api(
                  `/alerts/${r.AlertId}/${r.Status === "PENDING" ? "acknowledge" : r.Status === "ACKNOWLEDGED" ? "resolve" : "reopen"}`,
                  "POST",
                  {},
                );
                await load();
              },
            ),
          ],
        );
      } else if (page === "events") {
        items = await api("/events?" + params());
        table(
          [
            ["EventId", "Mã"],
            ["HouseId", "Nhà yến"],
            ["ZoneId", "Khu vực"],
            ["EventType", "Sự kiện"],
            ["Message", "Nội dung"],
            ["Status", "Trạng thái"],
            ["EventAt", "Thời gian"],
          ],
          items,
          (r) =>
            r.Status === "RESOLVED"
              ? []
              : [
                  button(
                    r.Status === "NEW" ? "Xác nhận" : "Đã xử lý",
                    async () => {
                      await api(`/events/${r.EventId}/status`, "POST", {
                        expected_status: r.Status,
                        status:
                          r.Status === "NEW" ? "ACKNOWLEDGED" : "RESOLVED",
                      });
                      await load();
                    },
                  ),
                ],
        );
      } else if (page === "controls") {
        items = await api(
          "/controls" + (params().toString() ? "?" + params() : ""),
        );
        table(
          [
            ["DeviceId", "Mã"],
            ["DeviceName", "Thiết bị"],
            ["ZoneId", "Khu vực"],
            ["DeviceType", "Loại"],
            ["ControlMode", "Chế độ"],
            ["IsOn", "Trạng thái mô phỏng"],
            ["UpdatedAt", "Cập nhật"],
          ],
          items,
          (r) => [
            button("Thủ công: Bật", () =>
              control(r, { action: "MANUAL", is_on: true }),
            ),
            button("Thủ công: Tắt", () =>
              control(r, { action: "MANUAL", is_on: false }),
            ),
            button("Chế độ AUTO", () =>
              control(r, { action: "SET_MODE", mode: "AUTO" }),
            ),
            button("Áp dụng AUTO", async () => {
              const reading = prompt(
                "Mã số đo mới nhất của cảm biến cùng khu vực:",
              );
              if (reading === null) return;
              if (!/^\d+$/.test(reading) || Number(reading) <= 0) {
                message("Mã số đo phải là số nguyên dương.", true);
                return;
              }
              await control(r, { action: "AUTO", reading_id: reading });
            }),
          ],
        );
      }
      $("previous").disabled = !configs[page] || pageNo === 1;
      $("next").disabled = !configs[page] || pageNo * size >= total;
      message(
        "Đã cập nhật từ SQL Server lúc " +
          new Date().toLocaleTimeString("vi-VN") +
          "." +
          (["sensors", "alerts", "events"].includes(page)
            ? " Danh sách có giới hạn; dùng bộ lọc để thu hẹp dữ liệu."
            : ""),
      );
    } catch (err) {
      message(
        err.message +
          " Dữ liệu đang hiển thị (nếu có) là lần tải trước, chưa xác nhận mới.",
        true,
      );
    } finally {
      busy = false;
      $("refresh").disabled = false;
    }
  }
  async function control(r, data) {
    await api("/controls/" + r.DeviceId, "POST", data);
    await load();
  }
  // P2: nhan dashboard_update qua Socket.IO; mat ket noi thi polling 2s van chay.
  function startRealtime() {
    if (!window.io) return;
    const socket = io({ transports: ["websocket", "polling"] });
    socket.on("dashboard_update", () => {
      if (!document.hidden) load();
      refreshBell();
    });
    socket.on("new_alert", (a) => {
      refreshBell();
      if ("Notification" in window && Notification.permission === "granted") {
        new Notification(`Cảnh báo ${a.alert_type} — ${a.zone_name}`, {
          body: a.message,
        });
      }
    });
  }
  async function refreshBell() {
    try {
      const s = await api("/alerts/summary");
      $("alertBellCount").textContent = s.pending ?? 0;
    } catch (err) {
      // Bell giu gia tri cu neu khong lay duoc so lieu.
    }
  }
  async function start() {
    try {
      const state = await api("/auth");
      csrf = state.csrf_token;
      user = state.user;
      if (!user) {
        $("loginPanel").hidden = false;
        message("Vui lòng đăng nhập.");
        return;
      }
      $("account").append(
        node("span", `${user.UserName} · ${user.Role}`),
        button("Đăng xuất", async () => {
          await api("/auth/logout", "POST", {});
          location.href = "/login";
        }),
      );
      $("pageTitle").textContent = titles[page] || titles.dashboard;
      $("description").textContent =
        page === "birds"
          ? "Thống kê lượt di chuyển; không phải tổng số chim đang cư trú."
          : page === "analytics"
            ? "Tương quan giữa ổn định môi trường (giờ trong ngưỡng) và lượng chim ra/vào, lọc theo nhà yến, khu vực và khoảng ngày. Năng suất tạm đo bằng lượng chim vì chưa có bảng số tổ thu hoạch."
            : page === "controls"
              ? "Thay đổi trạng thái mô phỏng trong ứng dụng. Chưa kết nối phần cứng."
            : "Theo dõi và quản lý dữ liệu nhà yến.";
      if (page === "login") {
        location.replace("/");
        return;
      }
      await lookups();
      $("workspace").hidden = false;
      editor();
      filterSetup();
      await load();
      refreshBell();
      if ("Notification" in window && Notification.permission === "default") {
        Notification.requestPermission();
      }
      if (["dashboard", "alerts", "events", "controls"].includes(page)) {
        setInterval(() => {
          if (!document.hidden) load();
        }, 2000);
        startRealtime();
      }
    } catch (err) {
      message(err.message, true);
    }
  }
  $("loginForm").addEventListener("submit", async (e) => {
    e.preventDefault();
    const b = e.target.querySelector("button");
    b.disabled = true;
    try {
      const d = await api(
        "/auth/login",
        "POST",
        Object.fromEntries(new FormData(e.target)),
      );
      csrf = d.csrf_token;
      location.href = "/";
    } catch (err) {
      message(err.message, true);
    } finally {
      b.disabled = false;
    }
  });
  $("refresh").addEventListener("click", () => load());
  $("previous").addEventListener("click", () => {
    if (pageNo > 1) {
      pageNo--;
      load();
    }
  });
  $("next").addEventListener("click", () => {
    pageNo++;
    load();
  });
  $("chartMetric").addEventListener("change", chart);
  start();
})();
