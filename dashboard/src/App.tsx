import { useEffect } from "react";
import {
  BrowserRouter,
  Routes,
  Route,
  Navigate,
  useLocation,
  useNavigate,
} from "react-router-dom";
import { useAppStore } from "./stores/useAppStore";
import { NavBar } from "./components/molecules";
import { LoginPage, MonitoringPage, ProfilesPage, SettingsPage } from "./pages";
import * as api from "./services/api";
import {
  AUTH_REQUIRED_EVENT,
  clearStoredAuthToken,
  getStoredAuthToken,
} from "./services/auth";

function AppContent() {
  const {
    setInstances,
    setProfiles,
    setAgents,
    setServerInfo,
    applyMonitoringSnapshot,
    settings,
  } = useAppStore();
  const location = useLocation();
  const navigate = useNavigate();
  const memoryMetricsEnabled = settings.monitoring?.memoryMetrics ?? false;
  const authToken = getStoredAuthToken();
  const authenticated = authToken !== "";

  useEffect(() => {
    document.documentElement.setAttribute("data-site-mode", "agent");
  }, []);

  useEffect(() => {
    const handleAuthRequired = () => {
      clearStoredAuthToken();
      navigate("/login", {
        replace: true,
        state: { from: location.pathname },
      });
    };
    window.addEventListener(AUTH_REQUIRED_EVENT, handleAuthRequired);
    return () =>
      window.removeEventListener(AUTH_REQUIRED_EVENT, handleAuthRequired);
  }, [location.pathname, navigate]);

  useEffect(() => {
    if (!authenticated && location.pathname !== "/login") {
      navigate("/login", {
        replace: true,
        state: { from: location.pathname },
      });
    }
  }, [authenticated, location.pathname, navigate]);

  // Initial load
  useEffect(() => {
    if (!authenticated) {
      return;
    }
    const load = async () => {
      try {
        const [instances, profiles, health] = await Promise.all([
          api.fetchInstances(),
          api.fetchProfiles(),
          api.fetchHealth(),
        ]);
        setInstances(instances);
        setProfiles(profiles);
        setServerInfo(health);
      } catch (e) {
        console.error("Failed to load initial data", e);
      }
    };
    load();
  }, [authenticated, setInstances, setProfiles, setServerInfo]);

  // Subscribe to SSE events
  useEffect(() => {
    if (!authenticated) {
      return;
    }
    const unsubscribe = api.subscribeToEvents(
      {
        onInit: (agents) => {
          setAgents(agents);
        },
        onSystem: (event) => {
          console.log("System event:", event);
        },
        onAgent: (event) => {
          console.log("Agent event:", event);
        },
        onMonitoring: (snapshot) => {
          applyMonitoringSnapshot(snapshot, memoryMetricsEnabled);
        },
      },
      {
        includeMemory: memoryMetricsEnabled,
      },
    );

    return unsubscribe;
  }, [
    authenticated,
    applyMonitoringSnapshot,
    memoryMetricsEnabled,
    setAgents,
    setInstances,
    setProfiles,
  ]);

  if (!authenticated) {
    return (
      <Routes>
        <Route path="/login" element={<LoginPage />} />
        <Route path="*" element={<Navigate to="/login" replace />} />
      </Routes>
    );
  }

  return (
    <div className="dashboard-shell flex h-screen flex-col bg-bg-app">
      <NavBar />
      <main className="dashboard-grid flex-1 overflow-hidden">
        <Routes>
          <Route
            path="/"
            element={<Navigate to="/dashboard/monitoring" replace />}
          />
          <Route
            path="/login"
            element={<Navigate to="/dashboard/monitoring" replace />}
          />
          <Route
            path="/dashboard"
            element={<Navigate to="/dashboard/monitoring" replace />}
          />
          <Route path="/dashboard/monitoring" element={<MonitoringPage />} />
          <Route path="/dashboard/profiles" element={<ProfilesPage />} />
          <Route
            path="/dashboard/agents"
            element={<Navigate to="/dashboard/monitoring" replace />}
          />
          <Route path="/dashboard/settings" element={<SettingsPage />} />
          <Route
            path="*"
            element={<Navigate to="/dashboard/monitoring" replace />}
          />
        </Routes>
      </main>
    </div>
  );
}

export default function App() {
  return (
    <BrowserRouter>
      <AppContent />
    </BrowserRouter>
  );
}
