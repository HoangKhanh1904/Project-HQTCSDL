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
        ["Address", "Địa chỉ"],
        ["ManagerId", "Quản lý"],
        ["Status", "Trạng thái"],
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
    if (/At$|updated|RecordedAt/.test(key))
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
        for (const key of ["manager_id", "house_id", "zone_id"])
          if (key in data) data[key] = Number(data[key]);
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
      filters.addEventListener("input", () => renderEntity());
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
    if (["sensors", "birds"].includes(page)) {
      for (const [k, label] of [
        ["from", "Từ"],
        ["to", "Đến (không bao gồm)"],
      ]) {
        const input = field(filters, k, label, { type: "datetime-local" });
        const d = new Date(Date.now() - (k === "from" ? 86400000 : 0));
        input.value = new Date(d - d.getTimezoneOffset() * 60000)
          .toISOString()
          .slice(0, 16);
      }
    }
    if (["dashboard", "alerts", "controls"].includes(page)) {
      filters.hidden = true;
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
    const term = (
      f.querySelector("[name=search]").value || ""
    ).toLocaleLowerCase("vi");
    const status = f.querySelector("[name=status]").value;
    const records = items.filter(
      (r) =>
        (!status || r.Status === status) &&
        Object.values(r).join(" ").toLocaleLowerCase("vi").includes(term),
    );
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
      `Trang ${pageNo} · ${records.length}/${items.length} dòng trang này · tổng ${total}`;
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
    for (const [k, label, min, max] of [
      ["MinTemperature", "Nhiệt độ tối thiểu", -40, 100],
      ["MaxTemperature", "Nhiệt độ tối đa", -40, 100],
      ["MinHumidity", "Độ ẩm tối thiểu", 0, 100],
      ["MaxHumidity", "Độ ẩm tối đa", 0, 100],
    ]) {
      const i = field(form, k, label, {
        type: "number",
        min,
        maxValue: max,
        step: "0.01",
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
          const data = Object.fromEntries(
            [...new FormData(form)].map(([k, v]) => [k, Number(v)]),
          );
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
  async function load() {
    if (busy) return;
    busy = true;
    $("refresh").disabled = true;
    message("Đang tải dữ liệu…");
    try {
      if (configs[page]) {
        const d = await api(`/${page}?page=${pageNo}&limit=${size}`);
        items = d.items;
        total = d.total;
        renderEntity();
      } else if (page === "dashboard") {
        const d = await api("/dashboard/zones");
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
      } else if (page === "alerts") {
        items = await api("/alerts?limit=1000");
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
        items = await api("/controls");
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
              if (reading)
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
      if (["dashboard", "alerts", "events", "controls"].includes(page))
        setInterval(() => {
          if (!document.hidden) load();
        }, 10000);
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
