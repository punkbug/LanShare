document.addEventListener('DOMContentLoaded', () => {
  initTheme();
  detectOS();
  initTabs();
  initCopyButtons();
  initFAQ();
  initSimulator();
});

/* Theme Handling */
function initTheme() {
  const themeToggle = document.getElementById('theme-toggle');
  const storedTheme = localStorage.getItem('lanshare_theme');
  const systemPrefersLight = window.matchMedia('(prefers-color-scheme: light)').matches;

  if (storedTheme === 'light' || (!storedTheme && systemPrefersLight)) {
    document.documentElement.setAttribute('data-theme', 'light');
    themeToggle.innerHTML = '🌙';
  } else {
    document.documentElement.setAttribute('data-theme', 'dark');
    themeToggle.innerHTML = '☀️';
  }

  themeToggle.addEventListener('click', () => {
    const currentTheme = document.documentElement.getAttribute('data-theme');
    const newTheme = currentTheme === 'light' ? 'dark' : 'light';
    document.documentElement.setAttribute('data-theme', newTheme);
    localStorage.setItem('lanshare_theme', newTheme);
    themeToggle.innerHTML = newTheme === 'light' ? '🌙' : '☀️';
  });
}

/* OS Detection */
function detectOS() {
  const userAgent = window.navigator.userAgent.toLowerCase();
  const heroBtn = document.getElementById('hero-download-btn');
  const heroHint = document.getElementById('hero-os-hint');
  
  let os = 'macos';
  let label = 'macOS 다운로드 (.dmg)';
  let hint = 'macOS 13+ (Ventura, Sonoma, Sequoia 등 지원)';
  let targetTab = 'tab-macos';
  let href = 'downloads/LanShare-macOS.dmg';

  if (userAgent.indexOf('win') !== -1) {
    os = 'windows';
    label = 'Windows 패키지 다운로드 (.zip)';
    hint = 'Windows 10 / 11 64-bit 지원 (1-클릭 설치 및 실행)';
    targetTab = 'tab-windows';
    href = 'downloads/LanShare-Windows-Setup.zip';
  } else if (userAgent.indexOf('android') !== -1) {
    os = 'android';
    label = 'Android APK 다운로드 (.apk)';
    hint = 'Android 8.0 Oreo 이상 지원 (즉시 설치 가능)';
    targetTab = 'tab-android';
    href = 'downloads/LanShare-Android.apk';
  } else if (/iphone|ipad|ipod/.test(userAgent)) {
    os = 'ios';
    label = 'iOS 앱 다운로드 (.ipa)';
    hint = 'iOS 16+ 지원 (Sideloadly / AltStore 간편 설치)';
    targetTab = 'tab-ios';
    href = 'downloads/LanShare-iOS.ipa';
  }

  if (heroBtn) {
    heroBtn.textContent = label;
    heroBtn.setAttribute('href', href);
    heroBtn.setAttribute('download', '');
  }

  if (heroHint) {
    heroHint.textContent = `현재 접속 기기 감지: ${hint}`;
  }
}

/* Platform Tabs */
function initTabs() {
  const tabBtns = document.querySelectorAll('.tab-btn');
  const tabContents = document.querySelectorAll('.platform-content');

  tabBtns.forEach(btn => {
    btn.addEventListener('click', () => {
      const targetId = btn.getAttribute('data-target');
      
      tabBtns.forEach(b => b.classList.remove('active'));
      tabContents.forEach(c => c.classList.remove('active'));

      btn.classList.add('active');
      document.getElementById(targetId)?.classList.add('active');
    });
  });
}

/* Code Snippet Copy */
function initCopyButtons() {
  const copyButtons = document.querySelectorAll('.copy-btn');
  copyButtons.forEach(btn => {
    btn.addEventListener('click', async () => {
      const code = btn.parentElement.querySelector('code')?.innerText || '';
      try {
        await navigator.clipboard.writeText(code);
        const originalText = btn.textContent;
        btn.textContent = '복사됨!';
        btn.style.color = '#10b981';
        setTimeout(() => {
          btn.textContent = originalText;
          btn.style.color = '';
        }, 2000);
      } catch (err) {
        console.error('Failed to copy', err);
      }
    });
  });
}

/* FAQ Accordion */
function initFAQ() {
  const items = document.querySelectorAll('.faq-item');
  items.forEach(item => {
    const question = item.querySelector('.faq-question');
    question?.addEventListener('click', () => {
      const isOpen = item.classList.contains('open');
      items.forEach(i => i.classList.remove('open'));
      if (!isOpen) {
        item.classList.add('open');
      }
    });
  });
}

/* Web Audio API for Chime */
function playSuccessChime() {
  try {
    const AudioContext = window.AudioContext || window.webkitAudioContext;
    if (!AudioContext) return;
    const ctx = new AudioContext();
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();

    osc.type = 'sine';
    osc.frequency.setValueAtTime(587.33, ctx.currentTime); // D5
    osc.frequency.exponentialRampToValueAtTime(880, ctx.currentTime + 0.15); // A5

    gain.gain.setValueAtTime(0.15, ctx.currentTime);
    gain.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.5);

    osc.connect(gain);
    gain.connect(ctx.destination);

    osc.start();
    osc.stop(ctx.currentTime + 0.5);
  } catch (e) {
    // Ignore audio autoplay restrictions
  }
}

/* Interactive Simulator */
function initSimulator() {
  const dropArea = document.getElementById('sim-drop-area');
  const fileInput = document.getElementById('sim-file-input');
  const startBtn = document.getElementById('sim-start-btn');
  const resetBtn = document.getElementById('sim-reset-btn');
  const fileInfo = document.getElementById('sim-file-info');
  const targetDeviceSelect = document.getElementById('sim-target-device');
  const targetDeviceDisplay = document.getElementById('target-device-name');
  
  const progressBar = document.getElementById('sim-progress-bar');
  const progressPercent = document.getElementById('sim-progress-percent');
  const progressSpeed = document.getElementById('sim-progress-speed');
  const progressTransferred = document.getElementById('sim-progress-transferred');
  const packetLine = document.getElementById('sim-packet');
  const simStatus = document.getElementById('sim-status-label');

  let currentFile = {
    name: 'Sample_Design_4K.mov',
    sizeBytes: 1024 * 1024 * 342 // 342 MB
  };

  targetDeviceSelect?.addEventListener('change', () => {
    if (targetDeviceDisplay) {
      targetDeviceDisplay.textContent = targetDeviceSelect.value;
    }
  });

  dropArea?.addEventListener('click', () => fileInput?.click());

  ['dragenter', 'dragover'].forEach(eventName => {
    dropArea?.addEventListener(eventName, (e) => {
      e.preventDefault();
      dropArea.classList.add('dragover');
    });
  });

  ['dragleave', 'drop'].forEach(eventName => {
    dropArea?.addEventListener(eventName, (e) => {
      e.preventDefault();
      dropArea.classList.remove('dragover');
    });
  });

  dropArea?.addEventListener('drop', (e) => {
    const files = e.dataTransfer.files;
    if (files.length > 0) {
      handleSelectedFile(files[0]);
    }
  });

  fileInput?.addEventListener('change', (e) => {
    if (e.target.files.length > 0) {
      handleSelectedFile(e.target.files[0]);
    }
  });

  function handleSelectedFile(file) {
    currentFile = {
      name: file.name,
      sizeBytes: file.size
    };
    const sizeMb = (file.size / (1024 * 1024)).toFixed(1);
    if (fileInfo) {
      fileInfo.innerHTML = `선택된 파일: <strong>${file.name}</strong> (${sizeMb} MB)`;
    }
    resetSimulatorState();
  }

  let intervalId = null;

  startBtn?.addEventListener('click', () => {
    startBtn.disabled = true;
    startBtn.style.opacity = '0.5';
    resetBtn.style.display = 'inline-flex';

    simStatus.textContent = '상대 기기로 전송 요청 중… 수신 승인 대기';
    simStatus.style.color = 'var(--warning)';

    // Step 1: Simulate Peer Handshake (1 second)
    setTimeout(() => {
      simStatus.textContent = `수신 승인 완료! LAN 다이렉트 스트리밍 시작`;
      simStatus.style.color = 'var(--accent-primary)';
      packetLine?.classList.add('transmitting');

      let transferred = 0;
      const total = currentFile.sizeBytes;
      const baseChunk = total / 40; // 40 ticks (~2.4s)

      intervalId = setInterval(() => {
        // Random LAN speed between 75MB/s and 115MB/s
        const speedMb = (75 + Math.random() * 40).toFixed(1);
        transferred += baseChunk;

        if (transferred >= total) {
          transferred = total;
          clearInterval(intervalId);
          completeTransfer();
        }

        const pct = Math.min(100, Math.round((transferred / total) * 100));
        progressBar.style.width = `${pct}%`;
        progressPercent.textContent = `${pct}%`;
        progressSpeed.textContent = `${speedMb} MB/s`;
        
        const curMb = (transferred / (1024 * 1024)).toFixed(1);
        const totMb = (total / (1024 * 1024)).toFixed(1);
        progressTransferred.textContent = `${curMb} MB / ${totMb} MB`;
      }, 60);

    }, 900);
  });

  function completeTransfer() {
    packetLine?.classList.remove('transmitting');
    simStatus.textContent = '🎉 전송 성공! 상대 기기 다운로드 폴더에 안전하게 저장되었습니다.';
    simStatus.style.color = 'var(--success)';
    playSuccessChime();
    startBtn.disabled = false;
    startBtn.style.opacity = '1';
    startBtn.textContent = '다시 보내기';
  }

  function resetSimulatorState() {
    if (intervalId) clearInterval(intervalId);
    packetLine?.classList.remove('transmitting');
    progressBar.style.width = '0%';
    progressPercent.textContent = '0%';
    progressSpeed.textContent = '0 MB/s';
    const totMb = (currentFile.sizeBytes / (1024 * 1024)).toFixed(1);
    progressTransferred.textContent = `0 MB / ${totMb} MB`;
    simStatus.textContent = '대기 중: 파일을 드래그하거나 [전송 시작]을 누르세요';
    simStatus.style.color = 'var(--text-muted)';
    startBtn.disabled = false;
    startBtn.style.opacity = '1';
    startBtn.textContent = '전송 시작 (시뮬레이션)';
  }

  resetBtn?.addEventListener('click', resetSimulatorState);
}
