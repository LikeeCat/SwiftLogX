const { createApp } = Vue;

createApp({
  data() {
    return {
      currentLogData: [], // Stores all received log lines
      logWebSocket: null, // WebSocket instance
      MAX_LOG_LINES: 100000000,
      isLogProcessingPaused: false,
      currentLanguage: 'zh-CN', // Default language

      logSearchInputVal: '', // v-model for search input
      matchedLogLines: [], // Stores original indices of currently matched log lines in currentLogData
      currentMatchIndex: -1, // Index of the currently highlighted match in the matchedLogLines array
      isExporting: false, // 导出loading状态

      navigationHighlightClass: 'navigation-highlight', // Define CSS class name for navigation highlight

      // 简化的中文界面文本
      ui: {
        filterTitle: '日志操作',
        pauseLog: '暂停日志',
        resumeLog: '恢复日志',
        exportRawLog: '导出原始日志',
        exportingLog: '正在导出...',
        clearLog: '清除日志',
        searchPlaceholder: '搜索日志内容 (用逗号分隔多个关键词，例如: error, warn)...',
        previous: '上一条',
        next: '下一条',
        connecting: '正在连接到日志服务，等待实时日志...', 
        noMatch: (keyword) => `<div class="no-match-message">未找到匹配 "${keyword}" 的日志。</div>`,
        streaming: (count) => `实时日志流 (${count} 条)`,
        streamingSearch: (keyword) => `实时日志流 (搜索: "${keyword}")`,
        pausedStatus: (count) => `日志流已暂停，当前缓存 ${count} 条。`,
        logCleared: '日志已清除。',
        logPauseConsole: '日志处理已暂停。',
        logResumeConsole: '日志处理已恢复。'
      }
    };
  },
  computed: {
    hasSearchKeywords() {
      return this.logSearchInputVal.split(',').map(k => k.trim()).filter(k => k.length > 0).length > 0;
    },
    totalMatches() {
      return this.matchedLogLines.length;
    },
    logStatusMessage() {
      if (this.isLogProcessingPaused) {
        return this.ui.pausedStatus(this.currentLogData.length);
      } else {
        if (this.currentLogData.length === 0) {
          return this.ui.logCleared || this.ui.connecting;
        } else if (this.hasSearchKeywords) {
          return this.ui.streamingSearch(this.escapeHTML(this.logSearchInputVal));
        } else {
          return this.ui.streaming(this.currentLogData.length);
        }
      }
    },
    displayedLogLines() {
      const searchKeywords = this.logSearchInputVal.split(',').map(k => k.trim()).filter(k => k.length > 0);
      let logsToRender = [];
      this.matchedLogLines = []; // Reset matched lines

      if (searchKeywords.length > 0) {
        this.currentLogData.forEach((line, index) => {
          const lowerCaseLine = line.toLowerCase();
          const isMatch = searchKeywords.some(keyword => lowerCaseLine.includes(keyword.toLowerCase()));
          if (isMatch) {
            const formattedLine = this.formatLogLine(line);
            const highlightedLine = this.highlightKeywords(formattedLine, searchKeywords);
            logsToRender.push({ html: highlightedLine, originalIndex: index });
            this.matchedLogLines.push(index);
          }
        });
      } else {
        logsToRender = this.currentLogData.map((line, index) => {
          const formattedLine = this.formatLogLine(line);
          return { html: this.escapeHTML(formattedLine), originalIndex: index };
        });
        this.matchedLogLines = this.currentLogData.map((_, index) => index);
      }
      return logsToRender;
    }
  },
  methods: {
    /**
     * Updates the UI text based on the current language.
     */
    updateUIforLanguage() {
      // This method is now largely handled by Vue's reactivity in the template
      // We just need to ensure the computed properties and bindings are correct.
    },

    /**
     * Escapes HTML characters to prevent XSS attacks and tag interference.
     * @param {string} str - The string to escape.
     * @returns {string} The escaped string.
     */
    escapeHTML(str) {
      return str.replace(/[&<>"']/g, function (m) {
        return ({
          '&': '&amp;',
          '<': '&lt;',
          '>': '&gt;',
          '"': '&quot;',
          "'": '&#39;',
        })[m];
      });
    },

    /**
     * Highlights keywords in the log.
     * @param {string} text - The full log text.
     * @param {string[]} keywords - Array of keywords to highlight.
     * @returns {string} Log text with highlight HTML tags.
     */
    highlightKeywords(text, keywords) {
      if (!keywords || keywords.length === 0) return this.escapeHTML(text);

      let highlightedText = this.escapeHTML(text);

      keywords.forEach(keyword => {
        if (keyword) {
          const escapedKeyword = keyword.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
          const re = new RegExp(`(${escapedKeyword})`, 'gi');
          highlightedText = highlightedText.replace(re, '<mark>$1</mark>');
        }
      });
      return highlightedText;
    },

    /**
     * Returns original log line without any formatting.
     * @param {string} line - A single log line.
     * @returns {string} Original log text without any formatting.
     */
    formatLogLine(line) {
      // 直接返回原始日志内容，不进行任何格式化处理
      return line || '';
    },

    /**
     * Removes all temporary navigation highlights.
     * @returns {void}
     */
    removeNavigationHighlights() {
      // This is handled by Vue's reactivity and re-rendering of displayedLogLines
      // when search keywords change or navigation occurs.
    },

    /**
     * Filters and displays logs based on search keywords.
     * @returns {void}
     */
    displayFilteredLogs() {
      // This logic is now primarily handled by the `displayedLogLines` computed property.
      // We just need to ensure `updateMatchNavigation` is called to update match index and button states.
      this.updateMatchNavigation(true);
    },

    /**
     * Updates match count display and disables state of navigation buttons.
     * @param {boolean} highlightFirst - Whether to highlight the first match after updating.
     * @returns {void}
     */
    updateMatchNavigation(highlightFirst = false) {
      if (highlightFirst && this.totalMatches > 0) {
        this.currentMatchIndex = 0;
      } else if (this.totalMatches === 0) {
        this.currentMatchIndex = -1;
      } else if (this.currentMatchIndex >= this.totalMatches) {
        this.currentMatchIndex = this.totalMatches - 1;
        if (this.currentMatchIndex < 0) this.currentMatchIndex = -1;
      } else if (this.currentMatchIndex < 0 && this.totalMatches > 0) {
        this.currentMatchIndex = 0;
      }
      // The match count and button disabled states are now handled directly in the template
      // using computed properties and v-bind.

      if (this.currentMatchIndex !== -1) {
        this.$nextTick(() => {
          this.scrollToMatch(this.currentMatchIndex);
        });
      }
    },

    /**
     * Scrolls to and persistently highlights the specified match.
     * @param {number} index - Index of the match in the matchedLogLines array.
     * @returns {void}
     */
    scrollToMatch(index) {
      if (!this.hasSearchKeywords || index < 0 || index >= this.matchedLogLines.length) {
        return;
      }

      const originalLogIndexToHighlight = this.matchedLogLines[index];
      
      // Use $nextTick to ensure DOM is updated before scrolling
      this.$nextTick(() => {
        // Find the element using its data-original-index attribute
        const targetLogLineDiv = this.$refs.logContent.querySelector(`.log-line[data-original-index="${originalLogIndexToHighlight}"]`);
        
        if (targetLogLineDiv) {
          targetLogLineDiv.scrollIntoView({ behavior: 'smooth', block: 'center' });
        }
      });
    },

    /**
     * Navigates to the previous match result.
     * @returns {void}
     */
    navigatePrevMatch() {
      if (this.hasSearchKeywords && this.currentMatchIndex > 0) {
        this.currentMatchIndex--;
        this.updateMatchNavigation(false);
      }
    },

    /**
     * Navigates to the next match result.
     * @returns {void}
     */
    navigateNextMatch() {
      if (this.hasSearchKeywords && this.currentMatchIndex < this.matchedLogLines.length - 1) {
        this.currentMatchIndex++;
        this.updateMatchNavigation(false);
      }
    },

    /**
     * Initializes and manages WebSocket connection.
     * @returns {void}
     */
    setupWebSocket() {
      const wsProtocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
      const wsUrl = `${wsProtocol}//${window.location.host}/logs/ws`;

      if (this.logWebSocket) {
        this.logWebSocket.close();
      }

      this.logWebSocket = new WebSocket(wsUrl);

      this.logWebSocket.onopen = (event) => {
        console.log('WebSocket connection established ✅');
      };

      this.logWebSocket.onmessage = (event) => {
        const logContent = this.$refs.logContent;
        const isScrolledToBottom = logContent.scrollHeight - logContent.clientHeight <= logContent.scrollTop + 1;

        const receivedData = event.data;

        let receivedLines = [];
        try {
          receivedLines = JSON.parse(receivedData);
          if (!Array.isArray(receivedLines)) {
            console.warn("Received data is not an array, ignoring");
            receivedLines = [];
          }
        } catch (e) {
          console.error("Failed to parse log JSON:", e);
          receivedLines = [];
        }

        receivedLines.forEach(newLogLine => {
          this.currentLogData.push(newLogLine);
        });

        while (this.currentLogData.length > this.MAX_LOG_LINES) {
          this.currentLogData.shift();
        }

        if (isScrolledToBottom) {
          this.$nextTick(() => {
            logContent.scrollTop = logContent.scrollHeight;
          });
        }

        if (!this.isLogProcessingPaused) {
          // Reactivity will handle displayFilteredLogs and updateLogStatus
        }
      };
      
      this.logWebSocket.onclose = (event) => {
        console.log('WebSocket connection closed ❌');
        setTimeout(this.setupWebSocket, 3000);
      };

      this.logWebSocket.onerror = (error) => {
        console.error('WebSocket error:', error);
        this.logWebSocket.close();
      };
    },

    pauseLog() {
      this.isLogProcessingPaused = true;
      console.log(this.ui.logPauseConsole);
    },

    resumeLog() {
      this.isLogProcessingPaused = false;
      console.log(this.ui.logResumeConsole);
    },

    /**
     * 导出原始日志（直接下载源文件）
     */
    async exportRawLog() {
      if (this.isExporting) return; // 防止重复点击
      
      this.isExporting = true; // 开始loading
      
      try {
        const url = '/api/export/raw';
        
        const response = await fetch(url);
        if (!response.ok) {
          throw new Error(`HTTP ${response.status}: ${response.statusText}`);
        }
        
        const blob = await response.blob();
        const contentDisposition = response.headers.get('Content-Disposition');
        let filename = `原始日志_${new Date().getTime()}.txt`;
        
        if (contentDisposition) {
          const filenameMatch = contentDisposition.match(/filename\*?=["]?([^"]+)["]?/);
          if (filenameMatch) {
            filename = filenameMatch[1];
          }
        }
        
        const downloadUrl = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = downloadUrl;
        a.download = filename;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(downloadUrl);
        
        console.log(`原始日志文件已下载: ${filename}`);
        
      } catch (error) {
        console.error('下载原始日志文件失败:', error);
        alert('下载失败，请稍后重试。');
      } finally {
        this.isExporting = false; // 结束loading
      }
    },

    clearLog() {
      this.currentLogData = [];
      this.matchedLogLines = [];
      this.currentMatchIndex = -1;
      this.updateMatchNavigation();
      console.log('日志已从视图中清除。');
    },

    handleSearchInput() {
      this.currentMatchIndex = -1;
      this.updateMatchNavigation(true); // Re-evaluate matches and navigation
    },

    handleKeyDown(e) {
      if (e.altKey) {
        if (e.key === 'ArrowUp') {
          this.navigatePrevMatch();
          e.preventDefault();
        } else if (e.key === 'ArrowDown') {
          this.navigateNextMatch();
          e.preventDefault();
        }
      }
    },

    /**
     * 平滑滚动到日志内容顶部
     */
    scrollToTop() {
      console.log('滚动到顶部被点击');
      
      // 尝试多种方式获取日志容器元素
      const logContent = this.$refs.logContent || document.getElementById('logContent');
      
      if (logContent) {
        console.log('找到logContent元素，当前scrollTop:', logContent.scrollTop);
        console.log('元素信息 - scrollHeight:', logContent.scrollHeight, 'clientHeight:', logContent.clientHeight);
        
        // 使用多种方法确保滚动生效
        try {
          // 方法1: 直接设置scrollTop
          logContent.scrollTop = 0;
          
          // 方法2: 使用scrollTo
          logContent.scrollTo({
            top: 0,
            left: 0,
            behavior: 'smooth'
          });
          
          // 方法3: 使用requestAnimationFrame确保DOM更新
          this.$nextTick(() => {
            logContent.scrollTop = 0;
          });
          
          console.log('滚动操作完成，新的scrollTop:', logContent.scrollTop);
        } catch (error) {
          console.error('滚动操作失败:', error);
        }
      } else {
        console.error('未找到logContent元素');
        console.log('可用的refs:', Object.keys(this.$refs));
      }
    },

    /**
     * 平滑滚动到日志内容底部
     */
    scrollToBottom() {
      console.log('滚动到底部被点击');
      
      // 尝试多种方式获取日志容器元素
      const logContent = this.$refs.logContent || document.getElementById('logContent');
      
      if (logContent) {
        const maxScroll = logContent.scrollHeight - logContent.clientHeight;
        console.log('找到logContent元素，当前scrollTop:', logContent.scrollTop);
        console.log('目标scrollTop:', maxScroll, 'scrollHeight:', logContent.scrollHeight);
        
        // 使用多种方法确保滚动生效
        try {
          // 方法1: 直接设置scrollTop到最大值
          logContent.scrollTop = maxScroll;
          
          // 方法2: 使用scrollTo
          logContent.scrollTo({
            top: logContent.scrollHeight,
            left: 0,
            behavior: 'smooth'
          });
          
          // 方法3: 使用requestAnimationFrame确保DOM更新
          this.$nextTick(() => {
            logContent.scrollTop = logContent.scrollHeight;
          });
          
          console.log('滚动操作完成，新的scrollTop:', logContent.scrollTop);
        } catch (error) {
          console.error('滚动操作失败:', error);
        }
      } else {
        console.error('未找到logContent元素');
        console.log('可用的refs:', Object.keys(this.$refs));
      }
    }
  },
  mounted() {
    this.updateUIforLanguage(); // Initial UI update based on language
    this.setupWebSocket();

    // Initial update of match navigation
    this.updateMatchNavigation();

    // Add global keydown listener
    document.addEventListener('keydown', this.handleKeyDown);
  },
  beforeUnmount() {
    // Clean up global keydown listener
    document.removeEventListener('keydown', this.handleKeyDown);
    if (this.logWebSocket) {
      this.logWebSocket.close();
    }
  },
  template: `
    <div>
        <!-- 固定头部区域 -->
        <div class="fixed-header">
            <div class="top-controls-section">
                <div class="log-search-section">
                    <div class="search-input-wrapper">
                        <input
                            type="search"
                            id="logSearch"
                            :placeholder="ui.searchPlaceholder"
                            v-model="logSearchInputVal"
                            @input="handleSearchInput"
                        />
                        <span id="matchCount" class="match-count" aria-live="polite">{{ totalMatches > 0 ? (currentMatchIndex + 1) : 0 }} / {{ totalMatches }}</span>
                    </div>
                    <div class="search-nav-buttons">
                        <button id="prevMatchBtn" @click="navigatePrevMatch" :disabled="totalMatches === 0 || currentMatchIndex <= 0">
                            {{ ui.previous }}
                        </button>
                        <button id="nextMatchBtn" @click="navigateNextMatch" :disabled="totalMatches === 0 || currentMatchIndex >= totalMatches - 1">
                            {{ ui.next }}
                        </button>
                    </div>
                </div>

                <div class="operations-section">
                    <h2 id="filterTitle">{{ ui.filterTitle }}</h2>
                    
                    <div class="operations-buttons-row">
                        <button id="clearLogBtn" @click="clearLog">
                            {{ ui.clearLog }}
                        </button>
                        <div id="pauseResumeContainer">
                            <button id="pauseBtn" @click="pauseLog">
                                {{ ui.pauseLog }}
                            </button>
                            <button id="resumeBtn" @click="resumeLog">
                                {{ ui.resumeLog }}
                            </button>
                        </div>

                        <button id="exportRawLogBtn" @click="exportRawLog()" :disabled="isExporting" :class="{ 'loading': isExporting }">
                            <span v-if="isExporting" class="loading-spinner"></span>
                            {{ isExporting ? ui.exportingLog : ui.exportRawLog }}
                        </button>
                    </div>

                    <div id="logStatus" role="status" aria-live="polite" :class="{ paused: isLogProcessingPaused, spinning: currentLogData.length === 0 && !isLogProcessingPaused }">
                        {{ logStatusMessage }}
                    </div>
                </div>
            </div>
        </div>

        <!-- 主内容区域 -->
        <div class="container">
            <div class="log-display-section">
                <div id="logContent" tabindex="0" aria-live="polite" aria-atomic="true" ref="logContent">
                    <div v-if="displayedLogLines.length === 0 && !hasSearchKeywords" class="initial-message">
                        {{ ui.logCleared || ui.connecting }}
                    </div>
                    <div v-else-if="displayedLogLines.length === 0 && hasSearchKeywords" class="no-match-message" v-html="ui.noMatch(escapeHTML(logSearchInputVal))">
                    </div>
                    <div v-else>
                        <div
                            v-for="logLine in displayedLogLines"
                            :key="logLine.originalIndex"
                            class="log-line"
                            :data-original-index="logLine.originalIndex"
                            v-html="logLine.html"
                            :class="{ 'navigation-highlight': matchedLogLines[currentMatchIndex] === logLine.originalIndex && hasSearchKeywords }"
                        ></div>
                    </div>
                </div>
            </div>
        </div>
        
        <!-- 右下角悬浮按钮 -->
        <div class="floating-buttons">
            <button 
                class="float-btn scroll-to-top" 
                @click="scrollToTop"
                title="滚动到顶部"
                aria-label="滚动到日志顶部"
            >
                ↑
            </button>
            <button 
                class="float-btn scroll-to-bottom" 
                @click="scrollToBottom"
                title="滚动到底部"
                aria-label="滚动到日志底部"
            >
                ↓
            </button>
        </div>
    </div>
  `
}).mount('#app');