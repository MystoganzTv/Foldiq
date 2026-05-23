import { useState } from 'react';
import Sidebar    from './components/Sidebar';
import Welcome    from './screens/WelcomeScreen';
import Scan       from './screens/ScanScreen';
import Settings   from './screens/SettingsScreen';
import Preview    from './screens/PreviewScreen';
import Apply      from './screens/ApplyScreen';
import Report     from './screens/ReportScreen';
import styles     from './App.module.css';

const SCREENS = ['welcome', 'scan', 'settings', 'preview', 'apply', 'report'];

export default function App() {
  const [screen, setScreen]   = useState('welcome');
  const [folders, setFolders] = useState([]);
  const [files,   setFiles]   = useState([]);
  const [plan,    setPlan]    = useState([]);
  const [config,  setConfig]  = useState({
    outputFolder:   '',
    groupByMonth:   true,
    groupByDay:     true,
    copyMode:       false,
    skipDuplicates: true,
  });
  const [result, setResult]   = useState(null);

  function go(s) { setScreen(s); }

  const screenProps = { go, folders, setFolders, files, setFiles, plan, setPlan, config, setConfig, result, setResult };

  return (
    <div className={styles.layout}>
      <Sidebar screen={screen} screens={SCREENS} />
      <main className={styles.main}>
        {screen === 'welcome'  && <Welcome  {...screenProps} />}
        {screen === 'scan'     && <Scan     {...screenProps} />}
        {screen === 'settings' && <Settings {...screenProps} />}
        {screen === 'preview'  && <Preview  {...screenProps} />}
        {screen === 'apply'    && <Apply    {...screenProps} />}
        {screen === 'report'   && <Report   {...screenProps} />}
      </main>
    </div>
  );
}
