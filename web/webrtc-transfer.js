/**
 * LanShare WebRTC Direct P2P File Transfer Engine
 * 100% Serverless file transmission with DTLS end-to-end encryption
 */

(function () {
  const CHUNK_SIZE = 64 * 1024; // 64 KB
  const MAX_BUFFERED_AMOUNT = 8 * 1024 * 1024; // 8 MB

  let peer = null;
  let activeConn = null;
  let myPeerId = null;
  let remotePeerId = null;
  let qrcodeInstance = null;

  // Transfer State
  let currentFile = null;
  let incomingMetadata = null;
  let receivedChunks = [];
  let receivedBytes = 0;
  let transferStartTime = 0;

  // DOM Elements
  const el = {};

  document.addEventListener('DOMContentLoaded', () => {
    cacheElements();
    initPeer();
    setupEventListeners();
  });

  function cacheElements() {
    el.roleHostBtn = document.getElementById('web-role-host-btn');
    el.roleJoinBtn = document.getElementById('web-role-join-btn');
    el.hostPanel = document.getElementById('web-host-panel');
    el.joinPanel = document.getElementById('web-join-panel');
    el.transferPanel = document.getElementById('web-transfer-panel');

    el.roomCodeDisplay = document.getElementById('web-room-code-display');
    el.copyLinkBtn = document.getElementById('web-copy-link-btn');
    el.qrcodeContainer = document.getElementById('web-qrcode');

    el.joinCodeInput = document.getElementById('web-join-code-input');
    el.joinConnectBtn = document.getElementById('web-join-connect-btn');
    el.joinStatus = document.getElementById('web-join-status');

    el.connectedPeerName = document.getElementById('web-connected-peer-name');
    el.disconnectBtn = document.getElementById('web-disconnect-btn');

    el.dropZone = document.getElementById('web-dropzone');
    el.fileInput = document.getElementById('web-file-input');
    el.selectedFileInfo = document.getElementById('web-selected-file-info');
    el.sendBtn = document.getElementById('web-send-btn');

    el.progressContainer = document.getElementById('web-progress-container');
    el.progressFill = document.getElementById('web-progress-fill');
    el.progressText = document.getElementById('web-progress-text');
    el.progressSpeed = document.getElementById('web-progress-speed');
    el.progressTransferred = document.getElementById('web-progress-transferred');
    el.transferStatus = document.getElementById('web-transfer-status');

    // Receive Confirm Modal
    el.confirmModal = document.getElementById('web-confirm-modal');
    el.confirmFileName = document.getElementById('web-confirm-filename');
    el.confirmFileSize = document.getElementById('web-confirm-filesize');
    el.confirmAcceptBtn = document.getElementById('web-confirm-accept-btn');
    el.confirmRejectBtn = document.getElementById('web-confirm-reject-btn');
  }

  function generate4DigitCode() {
    return Math.floor(1000 + Math.random() * 9000).toString();
  }

  function formatBytes(bytes) {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
  }

  function getDeviceSummary() {
    const ua = navigator.userAgent;
    let os = '기기';
    if (/mac/i.test(ua)) os = 'Mac';
    else if (/win/i.test(ua)) os = 'Windows';
    else if (/android/i.test(ua)) os = 'Android';
    else if (/iphone|ipad/i.test(ua)) os = 'iPhone';
    return `${os} 브라우저`;
  }

  function initPeer() {
    // Check URL parameters for auto-join room code
    const urlParams = new URLSearchParams(window.location.search);
    const joinCodeParam = urlParams.get('room');

    const rawCode = generate4DigitCode();
    myPeerId = `lanshare-${rawCode}`;

    try {
      peer = new Peer(myPeerId, {
        debug: 1,
        config: {
          iceServers: [
            { urls: 'stun:stun.l.google.com:19302' },
            { urls: 'stun:global.stun.twilio.com:3478' }
          ]
        }
      });

      peer.on('open', (id) => {
        const shortCode = id.replace('lanshare-', '');
        if (el.roomCodeDisplay) el.roomCodeDisplay.textContent = shortCode;

        // Generate QR Code for easy smartphone connection
        const shareUrl = `${window.location.origin}${window.location.pathname}?room=${shortCode}#web-direct-transfer`;
        renderQRCode(shareUrl);

        if (joinCodeParam) {
          switchTab('join');
          el.joinCodeInput.value = joinCodeParam;
          setTimeout(() => connectToPeer(joinCodeParam), 500);
        }
      });

      peer.on('connection', (conn) => {
        setupConnection(conn);
      });

      peer.on('error', (err) => {
        console.warn('PeerJS event:', err.type, err);
        if (err.type === 'unavailable-id') {
          // Retry with new ID
          myPeerId = `lanshare-${generate4DigitCode()}`;
          peer.reconnect();
        } else if (el.joinStatus) {
          el.joinStatus.textContent = '연결 오류: ' + (err.message || '상대방 코드를 확인해주세요.');
          el.joinStatus.style.color = 'var(--danger)';
        }
      });
    } catch (e) {
      console.error('Peer init failed', e);
    }
  }

  function renderQRCode(text) {
    if (!el.qrcodeContainer || typeof QRCode === 'undefined') return;
    el.qrcodeContainer.innerHTML = '';
    try {
      qrcodeInstance = new QRCode(el.qrcodeContainer, {
        text: text,
        width: 140,
        height: 140,
        colorDark: '#0f172a',
        colorLight: '#ffffff',
        correctLevel: QRCode.CorrectLevel.M
      });
    } catch (e) {
      console.warn('QRCode render error', e);
    }
  }

  function setupEventListeners() {
    el.roleHostBtn?.addEventListener('click', () => switchTab('host'));
    el.roleJoinBtn?.addEventListener('click', () => switchTab('join'));

    el.copyLinkBtn?.addEventListener('click', () => {
      const code = el.roomCodeDisplay?.textContent || '';
      const shareUrl = `${window.location.origin}${window.location.pathname}?room=${code}#web-direct-transfer`;
      navigator.clipboard.writeText(shareUrl).then(() => {
        const prev = el.copyLinkBtn.textContent;
        el.copyLinkBtn.textContent = '✓ 복사 완료!';
        el.copyLinkBtn.style.color = 'var(--success)';
        setTimeout(() => {
          el.copyLinkBtn.textContent = prev;
          el.copyLinkBtn.style.color = '';
        }, 2000);
      });
    });

    el.joinConnectBtn?.addEventListener('click', () => {
      const code = el.joinCodeInput?.value?.trim();
      if (code && code.length >= 4) {
        connectToPeer(code);
      } else {
        el.joinStatus.textContent = '4자리 이상의 코드를 입력해주세요.';
        el.joinStatus.style.color = 'var(--danger)';
      }
    });

    el.disconnectBtn?.addEventListener('click', () => {
      if (activeConn) activeConn.close();
      resetToInitialUI();
    });

    // File Selection
    el.dropZone?.addEventListener('click', () => el.fileInput?.click());
    
    ['dragenter', 'dragover'].forEach(name => {
      el.dropZone?.addEventListener(name, (e) => {
        e.preventDefault();
        el.dropZone.classList.add('dragover');
      });
    });

    ['dragleave', 'drop'].forEach(name => {
      el.dropZone?.addEventListener(name, (e) => {
        e.preventDefault();
        el.dropZone.classList.remove('dragover');
      });
    });

    el.dropZone?.addEventListener('drop', (e) => {
      if (e.dataTransfer.files.length > 0) {
        handleFileChosen(e.dataTransfer.files[0]);
      }
    });

    el.fileInput?.addEventListener('change', (e) => {
      if (e.target.files.length > 0) {
        handleFileChosen(e.target.files[0]);
      }
    });

    el.sendBtn?.addEventListener('click', () => {
      if (!currentFile || !activeConn || !activeConn.open) return;
      initiateSendFile();
    });

    // Confirm Modal
    el.confirmAcceptBtn?.addEventListener('click', () => {
      el.confirmModal.style.display = 'none';
      if (activeConn) {
        activeConn.send({ type: 'TRANSFER_ACCEPT' });
        startReceivingState();
      }
    });

    el.confirmRejectBtn?.addEventListener('click', () => {
      el.confirmModal.style.display = 'none';
      if (activeConn) {
        activeConn.send({ type: 'TRANSFER_REJECT' });
      }
      resetTransferUI();
    });
  }

  function switchTab(role) {
    if (role === 'host') {
      el.roleHostBtn?.classList.add('active');
      el.roleJoinBtn?.classList.remove('active');
      if (el.hostPanel) el.hostPanel.style.display = 'block';
      if (el.joinPanel) el.joinPanel.style.display = 'none';
    } else {
      el.roleHostBtn?.classList.remove('active');
      el.roleJoinBtn?.classList.add('active');
      if (el.hostPanel) el.hostPanel.style.display = 'none';
      if (el.joinPanel) el.joinPanel.style.display = 'block';
    }
  }

  function connectToPeer(code) {
    const targetPeerId = `lanshare-${code.toLowerCase().replace(/[^a-z0-9]/g, '')}`;
    el.joinStatus.textContent = '상대 기기에 P2P 암호화 터널 연결 중…';
    el.joinStatus.style.color = 'var(--accent-primary)';
    el.joinConnectBtn.disabled = true;

    const conn = peer.connect(targetPeerId, {
      reliable: true,
      metadata: { device: getDeviceSummary() }
    });

    setupConnection(conn);
  }

  function setupConnection(conn) {
    activeConn = conn;

    conn.on('open', () => {
      remotePeerId = conn.peer;
      const remoteName = conn.metadata?.device || '상대방 기기';
      if (el.connectedPeerName) el.connectedPeerName.textContent = remoteName;

      // Show Transfer Panel
      if (el.hostPanel) el.hostPanel.style.display = 'none';
      if (el.joinPanel) el.joinPanel.style.display = 'none';
      if (el.roleHostBtn) el.roleHostBtn.parentElement.style.display = 'none';
      if (el.transferPanel) el.transferPanel.style.display = 'block';

      if (el.transferStatus) {
        el.transferStatus.textContent = '🔒 P2P 암호화 채널 연결 완료! 전송할 파일을 선택하세요.';
        el.transferStatus.style.color = 'var(--success)';
      }
    });

    conn.on('data', (data) => {
      handleIncomingData(data);
    });

    conn.on('close', () => {
      alert('상대방과의 P2P 연결이 종료되었습니다.');
      resetToInitialUI();
    });

    conn.on('error', (err) => {
      console.warn('Connection error:', err);
      if (el.joinStatus) {
        el.joinStatus.textContent = '연결 실패: 올바른 코드인지 확인해주세요.';
        el.joinStatus.style.color = 'var(--danger)';
        el.joinConnectBtn.disabled = false;
      }
    });
  }

  function handleFileChosen(file) {
    currentFile = file;
    if (el.selectedFileInfo) {
      el.selectedFileInfo.innerHTML = `선택된 파일: <strong>${file.name}</strong> (${formatBytes(file.size)})`;
    }
    if (el.sendBtn) el.sendBtn.disabled = false;
  }

  function initiateSendFile() {
    if (!currentFile || !activeConn) return;

    el.sendBtn.disabled = true;
    el.transferStatus.textContent = '상대 기기로 수신 승인 요청 중…';
    el.transferStatus.style.color = 'var(--warning)';

    // Step 1: Send Header
    activeConn.send({
      type: 'TRANSFER_REQUEST',
      name: currentFile.name,
      size: currentFile.size,
      mime: currentFile.type || 'application/octet-stream'
    });
  }

  function handleIncomingData(data) {
    if (!data) return;

    // Control Messages
    if (data.type === 'TRANSFER_REQUEST') {
      incomingMetadata = data;
      if (el.confirmFileName) el.confirmFileName.textContent = data.name;
      if (el.confirmFileSize) el.confirmFileSize.textContent = formatBytes(data.size);
      if (el.confirmModal) el.confirmModal.style.display = 'flex';
      return;
    }

    if (data.type === 'TRANSFER_REJECT') {
      alert('상대방이 파일 수신을 거절했습니다.');
      resetTransferUI();
      return;
    }

    if (data.type === 'TRANSFER_ACCEPT') {
      startSendingFile();
      return;
    }

    // Binary Chunk Received
    if (data.byteLength || data instanceof ArrayBuffer) {
      receivedChunks.push(data);
      receivedBytes += data.byteLength;

      updateTransferProgress(receivedBytes, incomingMetadata.size);

      if (receivedBytes >= incomingMetadata.size) {
        finishReceivingFile();
      }
    }
  }

  function startSendingFile() {
    el.progressContainer.style.display = 'block';
    el.transferStatus.textContent = '⚡ 로컬 P2P 다이렉트 암호화 전송 중…';
    el.transferStatus.style.color = 'var(--accent-primary)';

    transferStartTime = Date.now();
    let offset = 0;
    const total = currentFile.size;

    function readNextSlice() {
      if (offset >= total) {
        finishSendingFile();
        return;
      }

      // Flow Control (Prevent Buffer Overflow in WebRTC DataChannel)
      const dataChannel = activeConn.dataChannel;
      if (dataChannel && dataChannel.bufferedAmount > MAX_BUFFERED_AMOUNT) {
        setTimeout(readNextSlice, 25);
        return;
      }

      const slice = currentFile.slice(offset, offset + CHUNK_SIZE);
      const reader = new FileReader();

      reader.onload = function (e) {
        activeConn.send(e.target.result);
        offset += e.target.result.byteLength;
        updateTransferProgress(offset, total);
        readNextSlice();
      };

      reader.readAsArrayBuffer(slice);
    }

    readNextSlice();
  }

  function startReceivingState() {
    receivedChunks = [];
    receivedBytes = 0;
    transferStartTime = Date.now();
    el.progressContainer.style.display = 'block';
    el.transferStatus.textContent = '⚡ 상대방으로부터 로컬 P2P 수신 중…';
    el.transferStatus.style.color = 'var(--accent-primary)';
  }

  function updateTransferProgress(current, total) {
    const pct = Math.min(100, Math.round((current / total) * 100));
    if (el.progressFill) el.progressFill.style.width = `${pct}%`;
    if (el.progressText) el.progressText.textContent = `${pct}%`;

    const elapsedSec = (Date.now() - transferStartTime) / 1000;
    if (elapsedSec > 0.2) {
      const speedBytesPerSec = current / elapsedSec;
      if (el.progressSpeed) el.progressSpeed.textContent = `${formatBytes(speedBytesPerSec)}/s`;
    }

    if (el.progressTransferred) {
      el.progressTransferred.textContent = `${formatBytes(current)} / ${formatBytes(total)}`;
    }
  }

  function finishSendingFile() {
    el.transferStatus.textContent = '🎉 파일 전송 성공! 상대 기기에 저장이 완료되었습니다.';
    el.transferStatus.style.color = 'var(--success)';
    el.sendBtn.disabled = false;
    el.sendBtn.textContent = '다른 파일 보내기';
    playSuccessChime();
  }

  function finishReceivingFile() {
    el.transferStatus.textContent = '🎉 전송 완료! 다운로드 폴더에 파일을 저장합니다.';
    el.transferStatus.style.color = 'var(--success)';
    playSuccessChime();

    const blob = new Blob(receivedChunks, { type: incomingMetadata.mime });
    if (window.lanShareNative) {
      saveToNativeApp(blob, incomingMetadata.name, incomingMetadata.mime);
    } else {
      const blobUrl = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = blobUrl;
      a.download = incomingMetadata.name;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      setTimeout(() => URL.revokeObjectURL(blobUrl), 10000);
    }

    receivedChunks = [];
    receivedBytes = 0;
  }

  async function saveToNativeApp(blob, name, mime) {
    try {
      const bridge = window.lanShareNative;
      bridge.beginFile(name, mime || 'application/octet-stream', blob.size);
      const chunkSize = 48 * 1024;
      const reader = blob.stream().getReader();
      let pending = new Uint8Array(0);
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        const bytes = new Uint8Array(pending.length + value.length);
        bytes.set(pending);
        bytes.set(value, pending.length);
        let offset = 0;
        while (bytes.length - offset >= chunkSize) {
          const chunk = bytes.subarray(offset, offset + chunkSize);
          let binary = '';
          for (let i = 0; i < chunk.length; i++) binary += String.fromCharCode(chunk[i]);
          bridge.writeChunk(btoa(binary));
          offset += chunkSize;
        }
        pending = bytes.slice(offset);
      }
      if (pending.length) {
        let binary = '';
        for (let i = 0; i < pending.length; i++) binary += String.fromCharCode(pending[i]);
        bridge.writeChunk(btoa(binary));
      }
      bridge.completeFile();
      if (el.transferStatus) el.transferStatus.textContent = '🎉 전송 완료! 앱의 다운로드 폴더에 저장했습니다.';
    } catch (error) {
      console.error('Native save failed', error);
      if (el.transferStatus) el.transferStatus.textContent = '파일을 앱에 저장하지 못했습니다.';
    }
  }

  function resetTransferUI() {
    if (el.progressContainer) el.progressContainer.style.display = 'none';
    if (el.sendBtn) el.sendBtn.disabled = false;
    if (el.transferStatus) {
      el.transferStatus.textContent = '🔒 P2P 암호화 채널 연결됨. 전송할 파일을 선택하세요.';
      el.transferStatus.style.color = 'var(--success)';
    }
  }

  function resetToInitialUI() {
    if (activeConn) {
      try { activeConn.close(); } catch(e){}
      activeConn = null;
    }
    if (el.transferPanel) el.transferPanel.style.display = 'none';
    if (el.roleHostBtn) el.roleHostBtn.parentElement.style.display = 'flex';
    switchTab('host');
    if (el.joinConnectBtn) el.joinConnectBtn.disabled = false;
    if (el.joinStatus) el.joinStatus.textContent = '';
    currentFile = null;
    if (el.selectedFileInfo) el.selectedFileInfo.textContent = '선택된 파일이 없습니다.';
    resetTransferUI();
  }

  function playSuccessChime() {
    try {
      const AudioCtx = window.AudioContext || window.webkitAudioContext;
      if (!AudioCtx) return;
      const ctx = new AudioCtx();
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.type = 'sine';
      osc.frequency.setValueAtTime(587.33, ctx.currentTime);
      osc.frequency.exponentialRampToValueAtTime(880, ctx.currentTime + 0.15);
      gain.gain.setValueAtTime(0.2, ctx.currentTime);
      gain.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.6);
      osc.connect(gain);
      gain.connect(ctx.destination);
      osc.start();
      osc.stop(ctx.currentTime + 0.6);
    } catch(e){}
  }

})();
