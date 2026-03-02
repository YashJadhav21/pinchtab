import { useEffect, useState } from "react";
import { useAppStore } from "../stores/useAppStore";
import { Button, Card } from "../components/atoms";
import * as api from "../services/api";
import type { Settings } from "../types";

export default function SettingsPage() {
  const { settings, serverInfo, setSettings, setServerInfo } = useAppStore();
  const [local, setLocal] = useState<Settings>(settings);

  // Load server info on mount (settings come from localStorage via store)
  useEffect(() => {
    const load = async () => {
      try {
        const h = await api.fetchHealth();
        setServerInfo(h);
      } catch (e) {
        console.error("Failed to load server info", e);
      }
    };
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const handleSave = () => {
    // Settings are persisted to localStorage via setSettings
    setSettings(local);
  };

  const handleReset = () => setLocal(settings);

  return (
    <div className="flex flex-1 flex-col overflow-auto">
      <div className="sticky top-0 z-10 flex items-center justify-end gap-2 border-b border-border-subtle bg-bg-surface px-4 py-2">
        <Button variant="secondary" onClick={handleReset}>
          Reset
        </Button>
        <Button variant="primary" onClick={handleSave}>
          Apply Settings
        </Button>
      </div>

      <div className="mx-auto w-full max-w-2xl space-y-6 p-6">
        {/* Screencast */}
        <Card className="p-4">
          <h3 className="mb-4 text-sm font-semibold text-text-primary">
            📺 Screencast
          </h3>
          <div className="space-y-4">
            <div className="flex items-center justify-between">
              <label className="text-sm text-text-secondary">Frame Rate</label>
              <div className="flex items-center gap-2">
                <input
                  type="range"
                  min={1}
                  max={15}
                  value={local.screencast.fps}
                  onChange={(e) =>
                    setLocal({
                      ...local,
                      screencast: { ...local.screencast, fps: +e.target.value },
                    })
                  }
                  className="w-32"
                />
                <span className="w-12 text-right text-sm text-text-muted">
                  {local.screencast.fps} fps
                </span>
              </div>
            </div>
            <div className="flex items-center justify-between">
              <label className="text-sm text-text-secondary">Quality</label>
              <div className="flex items-center gap-2">
                <input
                  type="range"
                  min={10}
                  max={80}
                  value={local.screencast.quality}
                  onChange={(e) =>
                    setLocal({
                      ...local,
                      screencast: {
                        ...local.screencast,
                        quality: +e.target.value,
                      },
                    })
                  }
                  className="w-32"
                />
                <span className="w-12 text-right text-sm text-text-muted">
                  {local.screencast.quality}%
                </span>
              </div>
            </div>
            <div className="flex items-center justify-between">
              <label className="text-sm text-text-secondary">Max Width</label>
              <select
                value={local.screencast.maxWidth}
                onChange={(e) =>
                  setLocal({
                    ...local,
                    screencast: {
                      ...local.screencast,
                      maxWidth: +e.target.value,
                    },
                  })
                }
                className="rounded border border-border-default bg-bg-elevated px-2 py-1 text-sm text-text-primary"
              >
                {[400, 600, 800, 1024, 1280].map((w) => (
                  <option key={w} value={w}>
                    {w}px
                  </option>
                ))}
              </select>
            </div>
          </div>
        </Card>

        {/* Stealth */}
        <Card className="p-4">
          <h3 className="mb-4 text-sm font-semibold text-text-primary">
            🛡️ Stealth
          </h3>
          <div className="flex items-center justify-between">
            <label className="text-sm text-text-secondary">Level</label>
            <select
              value={local.stealth}
              onChange={(e) =>
                setLocal({
                  ...local,
                  stealth: e.target.value as "light" | "full",
                })
              }
              className="rounded border border-border-default bg-bg-elevated px-2 py-1 text-sm text-text-primary"
            >
              <option value="light">Light (default)</option>
              <option value="full">Full (canvas noise, WebGL, fonts)</option>
            </select>
          </div>
        </Card>

        {/* Browser */}
        <Card className="p-4">
          <h3 className="mb-4 text-sm font-semibold text-text-primary">
            🌐 Browser
          </h3>
          <div className="space-y-3">
            {[
              { key: "blockImages", label: "Block Images" },
              { key: "blockMedia", label: "Block Media" },
              { key: "noAnimations", label: "No Animations" },
            ].map(({ key, label }) => (
              <label key={key} className="flex items-center justify-between">
                <span className="text-sm text-text-secondary">{label}</span>
                <input
                  type="checkbox"
                  checked={local.browser[key as keyof typeof local.browser]}
                  onChange={(e) =>
                    setLocal({
                      ...local,
                      browser: { ...local.browser, [key]: e.target.checked },
                    })
                  }
                  className="h-4 w-4"
                />
              </label>
            ))}
          </div>
        </Card>

        {/* Monitoring */}
        <Card className="p-4">
          <h3 className="mb-4 text-sm font-semibold text-text-primary">
            📈 Monitoring
          </h3>
          <div className="space-y-3">
            <label className="flex items-center justify-between">
              <div>
                <span className="text-sm text-text-secondary">
                  Memory Metrics
                </span>
                <p className="text-xs text-text-muted">
                  Aggregate JS heap usage across tabs (can be heavy)
                </p>
              </div>
              <input
                type="checkbox"
                checked={local.monitoring?.memoryMetrics ?? false}
                onChange={(e) =>
                  setLocal({
                    ...local,
                    monitoring: {
                      ...local.monitoring,
                      memoryMetrics: e.target.checked,
                    },
                  })
                }
                className="h-4 w-4"
              />
            </label>
          </div>
        </Card>

        {/* Server Info */}
        {serverInfo && (
          <Card className="p-4">
            <h3 className="mb-4 text-sm font-semibold text-text-primary">
              📊 Server Info
            </h3>
            <div className="grid grid-cols-2 gap-2 text-sm">
              <div className="text-text-muted">Version</div>
              <div className="text-text-secondary">{serverInfo.version}</div>
              <div className="text-text-muted">Profiles</div>
              <div className="text-text-secondary">{serverInfo.profiles}</div>
              <div className="text-text-muted">Instances</div>
              <div className="text-text-secondary">{serverInfo.instances}</div>
              <div className="text-text-muted">Agents</div>
              <div className="text-text-secondary">{serverInfo.agents}</div>
            </div>
          </Card>
        )}
      </div>
    </div>
  );
}
