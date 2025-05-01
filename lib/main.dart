// main.dart
// Main application file for Multi-Provider MCP LLM integration

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:mcp_llm/mcp_llm.dart';
import 'multi_provider_manager.dart';

// Create logger instance
final logger = Logger.getLogger('MPApp');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Configure logger
  Logger.setAllLevels(LogLevel.info);
  Logger.setLevelByPattern('MultiProviderManager', LogLevel.debug);

  logger.info('Starting Multi-Provider MCP LLM Demo');

  await dotenv.load();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Multi-Provider MCP LLM Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MultiProviderChatScreen(),
    );
  }
}

class MultiProviderChatScreen extends StatefulWidget {
  const MultiProviderChatScreen({Key? key}) : super(key: key);

  @override
  State<MultiProviderChatScreen> createState() => _MultiProviderChatScreenState();
}

class _MultiProviderChatScreenState extends State<MultiProviderChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final List<ChatMessage> _messages = [];

  late MultiProviderManager _providerManager;
  String _selectedProvider = '';
  bool _isLoading = true;
  bool _isStreaming = false;
  bool _mcpConnected = false;
  Map<String, ProviderStatus> _providerStatus = {};

  @override
  void initState() {
    super.initState();
    logger.debug('Initializing chat screen');
    _initialize();
  }

  // Initialize the manager
  Future<void> _initialize() async {
    try {
      logger.info('Creating MultiProviderManager');
      _providerManager = MultiProviderManager();

      // Listen for connection state changes
      _providerManager.connectionState.listen((connected) {
        logger.debug('MCP connection state: $connected');
        setState(() {
          _mcpConnected = connected;
        });
      });

      // Listen for provider status changes
      _providerManager.providerStatus.listen((status) {
        logger.debug('Provider status updated');
        setState(() {
          _providerStatus = status;
        });
      });

      // Initialize MCP and LLM providers
      await _providerManager.initialize(
        mcpServerUrl: dotenv.env['MCP_SERVER_URL'] ?? 'http://localhost:8999/sse',
        mcpAuthToken: dotenv.env['MCP_AUTH_TOKEN'],
        openaiApiKey: dotenv.env['OPENAI_API_KEY'],
        claudeApiKey: dotenv.env['CLAUDE_API_KEY'] ?? dotenv.env['ANTHROPIC_API_KEY'],
      );

      logger.info('MultiProviderManager initialized');

      // Set default provider
      setState(() {
        _isLoading = false;
        if (_providerManager.availableProviders.isNotEmpty) {
          _selectedProvider = _providerManager.availableProviders.first;
          logger.debug('Default provider: $_selectedProvider');
        }
      });

      // Check available tools
      _checkAvailableTools();

    } catch (e) {
      logger.error('Error initializing: $e');
      setState(() {
        _isLoading = false;
        _messages.add(ChatMessage(
          text: 'Error initializing: $e',
          isUser: false,
          isError: true,
        ));
      });
    }
  }

  // Check available MCP tools
  Future<void> _checkAvailableTools() async {
    try {
      logger.info('Checking available tools');
      final tools = await _providerManager.getAvailableTools();

      if (tools.isNotEmpty) {
        logger.info('Found ${tools.length} tools');
        setState(() {
          _messages.add(ChatMessage(
            text: 'Available tools:\n' +
                tools.map((t) => '- ${t.name}: ${t.description}').join('\n'),
            isUser: false,
          ));
        });
      } else {
        logger.info('No tools available');
      }
    } catch (e) {
      logger.warning('Error checking tools: $e');
      // Ignore errors
    }
  }

  // Handle message sending
  void _sendMessage(String text) async {
    if (text.trim().isEmpty) return;

    _textController.clear();
    logger.info('User message: ${text.length > 50 ? "${text.substring(0, 50)}..." : text}');

    setState(() {
      _messages.add(ChatMessage(
        text: text,
        isUser: true,
      ));
    });

    if (text.startsWith('/compare ')) {
      // Compare providers
      _compareProviders(text.substring('/compare '.length));
    } else if (text.startsWith('/provider ')) {
      // Change provider
      _changeProvider(text.substring('/provider '.length).trim());
    } else if (text.startsWith('/stream ')) {
      // Stream response
      _streamResponse(text.substring('/stream '.length));
    } else if (text.startsWith('/smart ')) {
      // Auto-select provider
      _smartExecute(text.substring('/smart '.length));
    } else {
      // Regular chat
      _regularChat(text);
    }
  }

  // Change provider
  void _changeProvider(String newProvider) {
    logger.info('Changing provider to: $newProvider');

    if (_providerManager.availableProviders.contains(newProvider)) {
      logger.info('Provider changed');
      setState(() {
        _selectedProvider = newProvider;
        _messages.add(ChatMessage(
          text: 'Switched to provider: $newProvider',
          isUser: false,
        ));
      });
    } else {
      logger.warning('Unknown provider requested');
      setState(() {
        _messages.add(ChatMessage(
          text: 'Unknown provider: $newProvider\nAvailable providers: ${_providerManager.availableProviders.join(', ')}',
          isUser: false,
          isError: true,
        ));
      });
    }
  }

  // Regular chat request
  void _regularChat(String text) async {
    if (_selectedProvider.isEmpty) {
      logger.warning('No provider selected');
      setState(() {
        _messages.add(ChatMessage(
          text: 'No provider selected',
          isUser: false,
          isError: true,
        ));
      });
      return;
    }

    try {
      setState(() {
        _isLoading = true;
      });

      logger.info('Sending chat to: $_selectedProvider');
      final response = await _providerManager.chat(_selectedProvider, text);

      setState(() {
        _isLoading = false;
        _messages.add(ChatMessage(
          text: response.text,
          isUser: false,
          providerName: _selectedProvider,
          toolCalls: response.toolCalls,
        ));
      });

      logger.info('Response received');
    } catch (e) {
      logger.error('Chat error: $e');
      setState(() {
        _isLoading = false;
        _messages.add(ChatMessage(
          text: 'Error: $e',
          isUser: false,
          isError: true,
        ));
      });
    }
  }

  // Stream response request
  void _streamResponse(String text) async {
    if (_selectedProvider.isEmpty) {
      logger.warning('No provider selected for streaming');
      setState(() {
        _messages.add(ChatMessage(
          text: 'No provider selected',
          isUser: false,
          isError: true,
        ));
      });
      return;
    }

    try {
      setState(() {
        _isStreaming = true;
        // Add placeholder for streaming response
        _messages.add(ChatMessage(
          text: '',
          isUser: false,
          providerName: _selectedProvider,
        ));
      });

      logger.info('Starting stream chat');
      final responseStream = _providerManager.streamChat(_selectedProvider, text);

      String fullResponse = '';
      List<dynamic>? toolCalls;

      await for (final chunk in responseStream) {
        // Add text chunks
        if (chunk.textChunk.isNotEmpty) {
          fullResponse += chunk.textChunk;
          logger.debug('Text chunk received');

          setState(() {
            _messages.last = ChatMessage(
              text: fullResponse,
              isUser: false,
              providerName: _selectedProvider,
              toolCalls: toolCalls,
            );
          });
        }

        // Handle tool calls
        if (chunk.toolCalls != null) {
          toolCalls = chunk.toolCalls;
          logger.debug('Tool calls received');

          setState(() {
            _messages.last = ChatMessage(
              text: fullResponse,
              isUser: false,
              providerName: _selectedProvider,
              toolCalls: toolCalls,
            );
          });
        }

        // Check for stream completion
        if (chunk.isDone == true) {
          logger.info('Stream completed');
          setState(() {
            _isStreaming = false;
          });
        }
      }
    } catch (e) {
      logger.error('Stream error: $e');
      setState(() {
        _isStreaming = false;
        _messages.add(ChatMessage(
          text: 'Streaming error: $e',
          isUser: false,
          isError: true,
        ));
      });
    }
  }

  // Compare providers
  void _compareProviders(String text) async {
    try {
      logger.info('Comparing providers');
      setState(() {
        _isLoading = true;
        _messages.add(ChatMessage(
          text: 'Comparing providers...',
          isUser: false,
        ));
      });

      final responses = await _providerManager.executeAcrossProviders(text);

      // Create comparison message
      final sb = StringBuffer('Comparison results:\n\n');

      for (final provider in responses.keys) {
        sb.writeln('--- $provider ---');
        sb.writeln(responses[provider]!.text);
        sb.writeln();
      }

      logger.info('Comparison completed');
      setState(() {
        _isLoading = false;
        // Replace "comparing" message with results
        _messages.last = ChatMessage(
          text: sb.toString(),
          isUser: false,
          isComparison: true,
        );
      });
    } catch (e) {
      logger.error('Comparison error: $e');
      setState(() {
        _isLoading = false;
        _messages.add(ChatMessage(
          text: 'Comparison error: $e',
          isUser: false,
          isError: true,
        ));
      });
    }
  }

  // Auto-select best provider and execute
  void _smartExecute(String text) async {
    try {
      logger.info('Smart execute with auto-selection');
      setState(() {
        _isLoading = true;
      });

      final result = await _providerManager.smartExecute(text);

      setState(() {
        _isLoading = false;

        if (result.isSuccess) {
          logger.info('Smart execute success');
          _messages.add(ChatMessage(
            text: result.response!.text,
            isUser: false,
            providerName: result.provider,
            toolCalls: result.response!.toolCalls,
            isAutoSelected: true,
          ));
        } else {
          logger.error('Smart execute failed');
          _messages.add(ChatMessage(
            text: 'Error with provider ${result.provider}: ${result.error}',
            isUser: false,
            isError: true,
          ));
        }
      });
    } catch (e) {
      logger.error('Smart execute error: $e');
      setState(() {
        _isLoading = false;
        _messages.add(ChatMessage(
          text: 'Error: $e',
          isUser: false,
          isError: true,
        ));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Multi-Provider AI Chat'),
        actions: [
          // Provider selector
          DropdownButton<String>(
            value: _selectedProvider.isEmpty ? null : _selectedProvider,
            hint: const Text('Select Provider'),
            onChanged: (String? newValue) {
              if (newValue != null) {
                logger.info('User selected provider: $newValue');
                setState(() {
                  _selectedProvider = newValue;
                });
              }
            },
            items: _providerManager.availableProviders
                .map<DropdownMenuItem<String>>((String value) {
              // Show provider status with icon
              IconData iconData;
              Color iconColor;

              switch (_providerStatus[value]) {
                case ProviderStatus.ready:
                  iconData = Icons.check_circle;
                  iconColor = Colors.green;
                  break;
                case ProviderStatus.processing:
                  iconData = Icons.hourglass_top;
                  iconColor = Colors.orange;
                  break;
                case ProviderStatus.error:
                  iconData = Icons.error;
                  iconColor = Colors.red;
                  break;
                case ProviderStatus.initializing:
                  iconData = Icons.pending;
                  iconColor = Colors.blue;
                  break;
                case ProviderStatus.unknown:
                default:
                  iconData = Icons.help;
                  iconColor = Colors.grey;
                  break;
              }

              return DropdownMenuItem<String>(
                value: value,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(iconData, color: iconColor, size: 16),
                    const SizedBox(width: 8),
                    Text(value),
                  ],
                ),
              );
            }).toList(),
          ),
          const SizedBox(width: 8),
          // MCP connection status
          Icon(
            _mcpConnected ? Icons.cloud_done : Icons.cloud_off,
            color: _mcpConnected ? Colors.green : Colors.red,
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: _isLoading && _messages.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(8.0),
              itemCount: _messages.length,
              itemBuilder: (_, index) => _messages[index],
            ),
          ),
          if (_isLoading || _isStreaming)
            const Padding(
              padding: EdgeInsets.all(8.0),
              child: LinearProgressIndicator(),
            ),
          const Divider(height: 1.0),
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
            ),
            child: _buildTextComposer(),
          ),
        ],
      ),
    );
  }

  // Build text input widget
  Widget _buildTextComposer() {
    return IconTheme(
      data: IconThemeData(color: Theme.of(context).colorScheme.primary),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8.0),
        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
        child: Row(
          children: [
            Flexible(
              child: TextField(
                controller: _textController,
                onSubmitted: _sendMessage,
                decoration: const InputDecoration.collapsed(
                  hintText: 'Send a message or try /compare, /provider, /stream, /smart',
                ),
              ),
            ),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 4.0),
              child: IconButton(
                icon: const Icon(Icons.send),
                onPressed: () => _sendMessage(_textController.text),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    logger.info('Disposing chat screen');
    _providerManager.dispose();
    _textController.dispose();
    super.dispose();
  }
}

/// Chat message widget
class ChatMessage extends StatelessWidget {
  final String text;
  final bool isUser;
  final String? providerName;
  final List<dynamic>? toolCalls;
  final bool isError;
  final bool isComparison;
  final bool isAutoSelected;

  const ChatMessage({
    Key? key,
    required this.text,
    required this.isUser,
    this.providerName,
    this.toolCalls,
    this.isError = false,
    this.isComparison = false,
    this.isAutoSelected = false,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(right: 16.0),
            child: CircleAvatar(
              backgroundColor: _getAvatarColor(context),
              child: Text(isUser ? 'U' : _getAvatarText()),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      isUser ? 'You' : _getSenderText(),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: isError ? Colors.red : null,
                      ),
                    ),
                    if (isAutoSelected)
                      Padding(
                        padding: const EdgeInsets.only(left: 8.0),
                        child: Chip(
                          label: const Text('Auto-selected'),
                          backgroundColor: Colors.blue.shade100,
                          labelStyle: const TextStyle(fontSize: 10),
                          padding: EdgeInsets.zero,
                          labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                      ),
                  ],
                ),
                Container(
                  margin: const EdgeInsets.only(top: 5.0),
                  child: isComparison
                      ? _buildComparisonView()
                      : Text(text),
                ),
                if (toolCalls != null && toolCalls!.isNotEmpty)
                  _buildToolCallsView(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Build comparison view
  Widget _buildComparisonView() {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(8),
      child: Text(text),
    );
  }

  // Build tool calls view
  Widget _buildToolCallsView(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 10.0),
      padding: const EdgeInsets.all(8.0),
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(8.0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Tools used:',
            style: Theme.of(context).textTheme.bodySmall!.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          ...toolCalls!.map((toolCall) => Padding(
            padding: const EdgeInsets.only(top: 4.0),
            child: Text(
              '- ${toolCall["name"] ?? "Unknown"}: ${jsonEncode(toolCall["arguments"] ?? {})}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          )),
        ],
      ),
    );
  }

  // Get avatar color
  Color _getAvatarColor(BuildContext context) {
    if (isUser) {
      return Theme.of(context).colorScheme.primary;
    } else if (isError) {
      return Colors.red;
    } else if (providerName != null) {
      // Different color for each provider
      switch (providerName) {
        case 'openai':
          return Colors.green;
        case 'claude':
          return Colors.purple;
        default:
          return Theme.of(context).colorScheme.secondary;
      }
    } else {
      return Theme.of(context).colorScheme.secondary;
    }
  }

  // Get avatar text
  String _getAvatarText() {
    if (isError) {
      return 'E';
    } else if (providerName != null) {
      // First letter of provider name
      return providerName![0].toUpperCase();
    } else {
      return 'A';
    }
  }

  // Get sender text
  String _getSenderText() {
    if (isError) {
      return 'Error';
    } else if (providerName != null) {
      return providerName!;
    } else {
      return 'AI Assistant';
    }
  }
}