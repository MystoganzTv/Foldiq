import { useEffect, useState } from 'react';
import StepBar    from './components/StepBar';
import Welcome    from './screens/WelcomeScreen';
import Scan       from './screens/ScanScreen';
import Settings   from './screens/SettingsScreen';
import Preview    from './screens/PreviewScreen';
import Apply      from './screens/ApplyScreen';
import Report     from './screens/ReportScreen';
import './styles/global.css';

export default function App() {
  const [screen, setScreen]   = useState('welcome');
  const [folders, setFolders] = useState([]);
  const [files,   setFiles]   = useState([]);
  const [plan,    setPlan]    = useState([]);
  const [config,  setConfig]  = useState({
    outputFolder:   '',
    organizationMode: 'smart',
    groupByMonth:   true,
    groupByDay:     true,
    copyMode:       false,
    duplicateHandling: 'separate',
    includeVideos: true,
    includeArchives: true,
    useGPSLocation: false,
    renameByDate: false,
    shareAnonymousUsageData: false,
  });
  const [result, setResult] = useState(null);
  const [preferencesReady, setPreferencesReady] = useState(false);

  useEffect(() => {
    let active = true;
    window.foldiq.getPreferences()
      .then(saved => {
        if (active && saved) setConfig(current => ({ ...current, ...saved }));
      })
      .finally(() => { if (active) setPreferencesReady(true); });
    return () => { active = false; };
  }, []);

  useEffect(() => {
    if (!preferencesReady) return;
    window.foldiq.savePreferences(config).catch(() => {});
  }, [config, preferencesReady]);

  function go(s) { setScreen(s); }

  const screenProps = { go, folders, setFolders, files, setFiles, plan, setPlan, config, setConfig, result, setResult };

  const showStepBar = screen !== 'welcome';

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100vh', background: '#fff' }}>
      {showStepBar && <StepBar screen={screen} />}
      <div style={{ flex: 1, overflow: 'hidden', display: 'flex', flexDirection: 'column' }}>
        {screen === 'welcome'  && <Welcome  {...screenProps} />}
        {screen === 'scan'     && <Scan     {...screenProps} />}
        {screen === 'settings' && <Settings {...screenProps} />}
        {screen === 'preview'  && <Preview  {...screenProps} />}
        {screen === 'apply'    && <Apply    {...screenProps} />}
        {screen === 'report'   && <Report   {...screenProps} />}
      </div>
    </div>
  );
}
