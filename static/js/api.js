
/**
 * SwiftletCare - API client
 *
 * Hien tai: chua ket noi backend that.
 * Khi TV2 hoan thanh API, frontend se goi endpoint cua TV2.
 * Khong ket noi SQL Server truc tiep tu trinh duyet.
 */

(function () {
    "use strict";

    const API_BASE_URL = ""; // Cung domain voi Flask; chua can doi.

    async function request(path, options = {}) {
        const response = await fetch(`${API_BASE_URL}${path}`, {
            ...options,
            headers: {
                Accept: "application/json",
                ...(options.body ? { "Content-Type": "application/json" } : {}),
                ...options.headers
            }
        });

        let result;

        try {
            result = await response.json();
        } catch {
            throw new Error(`API tra ve du lieu khong hop le (HTTP ${response.status}).`);
        }

        if (!response.ok || result.success === false) {
            throw new Error(
                result.message || `Yeu cau API that bai (HTTP ${response.status}).`
            );
        }

        return result;
    }

    window.SwiftletAPI = {
        get(path) {
            return request(path);
        },

        post(path, data) {
            return request(path, {
                method: "POST",
                body: JSON.stringify(data)
            });
        },

        put(path, data) {
            return request(path, {
                method: "PUT",
                body: JSON.stringify(data)
            });
        },

        delete(path) {
            return request(path, { method: "DELETE" });
        }
    };
})();
