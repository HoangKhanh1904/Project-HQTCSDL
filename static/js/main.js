
document.addEventListener("DOMContentLoaded", function () {
    const searchInput = document.getElementById("farmSearch");
    const statusFilter = document.getElementById("farmStatus");
    const farmTable = document.getElementById("farmTable");
    const farmForm = document.getElementById("farmForm");

    // Trang khong co bang nha yen thi khong xu ly
    if (!searchInput || !statusFilter || !farmTable || !farmForm) {
        return;
    }

    const tbody = farmTable.querySelector("tbody");
    const emptyRow = document.getElementById("farmEmpty");

    const nameInput = document.getElementById("farmName");
    const addressInput = document.getElementById("farmAddress");
    const areasInput = document.getElementById("farmAreas");
    const newStatusInput = document.getElementById("farmNewStatus");

    const statCards = document.querySelectorAll(".stat-card .stat-value");

    // Lay cac dong du lieu mau ban dau
    const initialRows = Array.from(tbody.querySelectorAll("tr"))
        .filter(row => row.id !== "farmEmpty");

    let nextId = initialRows.length + 1;

    function getStatus(row) {
        return row.querySelector(".badge")?.textContent.trim() || "";
    }

    function updateStats() {
        const rows = Array.from(tbody.querySelectorAll("tr"))
            .filter(row => row.id !== "farmEmpty");

        const total = rows.length;
        const active = rows.filter(row =>
            getStatus(row) === "─Éang hoß║ít ─æß╗Öng"
        ).length;
        const inactive = rows.filter(row =>
            getStatus(row) === "Ngß╗½ng hoß║ít ─æß╗Öng"
        ).length;

        if (statCards[0]) statCards[0].textContent = total;
        if (statCards[1]) statCards[1].textContent = active;
        if (statCards[2]) statCards[2].textContent = inactive;
    }

    function filterFarms() {
        const keyword = searchInput.value
            .trim()
            .toLocaleLowerCase("vi");

        const selectedStatus = statusFilter.value;
        let visibleCount = 0;

        const rows = Array.from(tbody.querySelectorAll("tr"))
            .filter(row => row.id !== "farmEmpty");

        rows.forEach(function (row) {
            const name = row.querySelector(".farm-name")
                ?.textContent.trim() || "";
            const address = row.querySelector(".farm-address")
                ?.textContent.trim() || "";

            const searchText = (name + " " + address)
                .toLocaleLowerCase("vi");

            const matchesKeyword = searchText.includes(keyword);
            const matchesStatus =
                selectedStatus === "" ||
                getStatus(row) === selectedStatus;

            const visible = matchesKeyword && matchesStatus;
            row.hidden = !visible;

            if (visible) visibleCount++;
        });

        if (emptyRow) {
            emptyRow.hidden = visibleCount > 0;
        }
    }

    function addFarmRow(name, address, areas, status) {
        const row = document.createElement("tr");

        const code = "NY" + String(nextId).padStart(3, "0");
        nextId++;

        const values = [code, name, address, areas];

        values.forEach(function (value, index) {
            const cell = document.createElement("td");
            cell.textContent = value;

            if (index === 1) cell.className = "farm-name";
            if (index === 2) cell.className = "farm-address";

            row.appendChild(cell);
        });

        const statusCell = document.createElement("td");
        const badge = document.createElement("span");

        badge.className = status === "─Éang hoß║ít ─æß╗Öng"
            ? "badge text-bg-success"
            : "badge text-bg-secondary";

        badge.textContent = status;
        statusCell.appendChild(badge);
        row.appendChild(statusCell);

        const actionCell = document.createElement("td");
        const editButton = document.createElement("button");

        editButton.type = "button";
        editButton.className = "btn btn-sm btn-outline-success";
        editButton.textContent = "Sß╗¡a";
        editButton.disabled = true;
        editButton.title = "Ch╞░a kß║┐t nß╗æi backend";

        actionCell.appendChild(editButton);
        row.appendChild(actionCell);

        tbody.insertBefore(row, emptyRow);
    }

    searchInput.addEventListener("input", filterFarms);
    statusFilter.addEventListener("change", filterFarms);

    farmForm.addEventListener("submit", function (event) {
        event.preventDefault();

        const name = nameInput.value.trim();
        const address = addressInput.value.trim();
        const areas = Number(areasInput.value);
        const status = newStatusInput.value;

        if (!name || !address) {
            alert("Vui l├▓ng nhß║¡p t├¬n v├á ─æß╗ïa chß╗ë nh├á yß║┐n.");
            return;
        }

        if (!Number.isInteger(areas) || areas < 0) {
            alert("Sß╗æ khu vß╗▒c phß║úi l├á sß╗æ nguy├¬n kh├┤ng ├óm.");
            return;
        }

        addFarmRow(name, address, areas, status);

        farmForm.reset();
        areasInput.value = 1;

        updateStats();
        filterFarms();

        const modalElement = document.getElementById("farmModal");
        const modal = bootstrap.Modal.getInstance(modalElement);

        if (modal) modal.hide();
    });

    updateStats();
    filterFarms();
});
