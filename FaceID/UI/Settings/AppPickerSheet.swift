//
//  AppPickerSheet.swift
//  Face ID
//
//  Picks apps to lock. Enumerates what's installed, filters by a search field, and
//  returns the chosen ones as persistable `LockedApp` values.
//
//  A sheet rather than a settings page: it's a modal choice with a definite "add
//  these" ending, and it needs the full window to show a few hundred rows comfortably.
//

import AppKit
import SwiftUI

struct AppPickerSheet: View {
    /// Already-locked bundle IDs — shown as disabled so the list can't grow a duplicate.
    let alreadyLocked: Set<String>
    let onAdd: ([LockedApp]) -> Void
    let onCancel: () -> Void

    @State private var apps: [InstalledAppsScanner.DiscoveredApp] = []
    @State private var isScanning = true
    @State private var query = ""
    @State private var selection: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 460, height: 520)
        .task { await loadApps() }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选择要锁定的应用")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SettingsMetrics.textPrimary)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsMetrics.textTertiary)
                TextField("搜索", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsMetrics.textPrimary)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsMetrics.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(SettingsMetrics.pickerPillFill))
            .overlay(Capsule().strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth))
        }
        .padding(16)
    }

    @ViewBuilder
    private var list: some View {
        if isScanning {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在扫描已安装的应用…")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsMetrics.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "questionmark.folder")
                    .font(.system(size: 24))
                    .foregroundStyle(SettingsMetrics.textTertiary)
                Text(query.isEmpty ? "没有找到应用。" : "没有匹配「\(query)」的应用。")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsMetrics.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { app in
                        row(app)
                        Divider().padding(.leading, 52)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(selectionSummary)
                .font(.system(size: 11))
                .foregroundStyle(SettingsMetrics.textTertiary)

            Spacer()

            Button("取消", action: onCancel)
                .keyboardShortcut(.cancelAction)

            Button("添加", action: commit)
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty)
        }
        .padding(14)
    }

    // MARK: - Row

    private func row(_ app: InstalledAppsScanner.DiscoveredApp) -> some View {
        let isLocked = alreadyLocked.contains(app.bundleIdentifier)
        let isSelected = selection.contains(app.bundleIdentifier)

        return Button {
            guard !isLocked else { return }
            if isSelected {
                selection.remove(app.bundleIdentifier)
            } else {
                selection.insert(app.bundleIdentifier)
            }
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text(app.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SettingsMetrics.textPrimary)
                        .lineLimit(1)
                    Text(isLocked ? "已锁定" : app.bundleIdentifier)
                        .font(.system(size: 10))
                        .foregroundStyle(SettingsMetrics.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Image(systemName: isLocked
                    ? "checkmark.circle.fill"
                    : (isSelected ? "checkmark.circle.fill" : "circle"))
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected || isLocked
                        ? FIDTheme.accent
                        : SettingsMetrics.textTertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .opacity(isLocked ? 0.45 : 1)
    }

    // MARK: - Data

    private var filtered: [InstalledAppsScanner.DiscoveredApp] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return apps }
        return apps.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmed)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var selectionSummary: String {
        selection.isEmpty ? "请选择一个或多个应用" : "已选 \(selection.count) 个"
    }

    /// Scans off the first frame so the sheet has already drawn before the
    /// directory walk runs — `InstalledAppsScanner` is main-actor bound, and
    /// several hundred bundles take long enough to be visible as a hitch.
    private func loadApps() async {
        if apps.isEmpty {
            await Task.yield()
            apps = InstalledAppsScanner.shared.scanInstalledApps()
        }
        isScanning = false
    }

    private func commit() {
        let scanner = InstalledAppsScanner.shared
        let chosen = apps
            .filter { selection.contains($0.bundleIdentifier) }
            .map { scanner.toLockedApp($0) }
        onAdd(chosen)
    }
}
