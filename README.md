# Integrating AI with Flutter: Connecting Multiple LLM Providers to MCP Ecosystem

![Multiple AI Providers Integration with Flutter](https://images.unsplash.com/photo-1488590528505-98d2b5aba04b?q=80&w=2070&auto=format&fit=crop)

## Introduction

Welcome to the fourth article in our "Integrating AI with Flutter" series, following our previous exploration of [Creating AI Services with LlmServer and mcp_server](https://medium.com/@mcpdevstudio/integrating-ai-with-flutter-creating-ai-services-with-llmserver-and-mcp-server-5a9b2c8e71d3). In today's rapidly evolving AI landscape, relying on a single language model provider is often insufficient for building robust, versatile applications. Different LLM providers excel in various tasks, and the Model Context Protocol (MCP) ecosystem offers a standardized way to interact with them all.

This article will guide you through integrating multiple LLM providers (OpenAI and Claude) with the MCP ecosystem in your Flutter applications, allowing you to leverage the unique strengths of each provider while maintaining a consistent developer experience.

## Table of Contents

1. [Integration Patterns for Different LLM Providers](#integration-patterns-for-different-llm-providers)
2. [LlmCapability System and MCP Feature Mapping](#llmcapability-system-and-mcp-feature-mapping)
3. [Provider-Specific MCP Tool Implementations](#provider-specific-mcp-tool-implementations)
4. [Runtime Provider Switching](#runtime-provider-switching)
5. [Building the MultiProviderManager](#building-the-multiprovider-manager)
6. [Smart Provider Selection](#smart-provider-selection)
7. [Creating a Multi-Provider User Interface](#creating-a-multi-provider-user-interface)
8. [Next Steps](#next-steps)

## Integration Patterns for Different LLM Providers

When integrating multiple LLM providers with the MCP ecosystem, it's essential to understand their unique characteristics and the value they bring to your application.

### Provider Characteristics

**OpenAI (GPT Models)**
- Excellent at code generation and debugging
- Well-implemented function calling capabilities
- Broad domain knowledge across multiple fields

**Anthropic (Claude Models)**
- Very long context window (up to 200K tokens)
- Strong document analysis capabilities
- Focus on safety and bias control

By integrating both these providers through the Model Context Protocol, you can create applications that select the optimal provider for each task while maintaining a consistent interface.

## LlmCapability System and MCP Feature Mapping

The `mcp_llm` package provides an `LlmCapability` system that abstracts the capabilities of different LLM providers. This system plays a crucial role in mapping provider-specific features to standardized MCP tools.

### Core Components of the LlmCapability System

```dart
class ProviderCapabilities {
  final bool supportsStreaming;
  final bool supportsToolCalls;
  final int maxContextLength;
  final Map<String, dynamic> specificCapabilities;

  ProviderCapabilities({
    required this.supportsStreaming,
    required this.supportsToolCalls,
    required this.maxContextLength,
    required this.specificCapabilities,
  });
}
```

This class represents the capabilities of an LLM provider and is used for MCP tool creation and feature enablement. The `specificCapabilities` map stores provider-specific features.

### Implementation of Capability Assessment

```dart
// Assess provider capabilities
ProviderCapabilities _assessProviderCapabilities(String providerName) {
  final capabilities = ProviderCapabilities(
    supportsStreaming: true,
    supportsToolCalls: true,
    maxContextLength: _getMaxContextLength(providerName),
    specificCapabilities: {},
  );

  // Add provider-specific capabilities
  switch (providerName.toLowerCase()) {
    case 'openai':
      capabilities.specificCapabilities['vision'] = true;
      capabilities.specificCapabilities['functionCalling'] = true;
      capabilities.specificCapabilities['codeCompletion'] = true;
      break;
    case 'claude':
      capabilities.specificCapabilities['vision'] = true;
      capabilities.specificCapabilities['documentAnalysis'] = true;
      capabilities.specificCapabilities['longContext'] = true;
      break;
  }

  return capabilities;
}
```

This function evaluates the capabilities of a provider based on its name, which can then be used for MCP tool creation and provider selection.

## Provider-Specific MCP Tool Implementations

Each LLM provider has differences in how they implement tool calling and features. For example, OpenAI uses 'function calling', while Claude has a more general tool calling mechanism. Here's how to handle these differences effectively:

### Implementation of Chat Methods

```dart
// Send chat message to provider
Future<LlmResponse> chat(String provider, String message, {bool enableTools = true}) async {
  final client = _llmClients[provider];
  if (client == null) {
    throw Exception('Provider $provider not available');
  }

  try {
    _updateProviderStatus(provider, ProviderStatus.processing);

    final response = await client.chat(
      message,
      enableTools: enableTools,
    );

    _updateProviderStatus(provider, ProviderStatus.ready);
    return response;
  } catch (e) {
    _updateProviderStatus(provider, ProviderStatus.error, error: e.toString());
    rethrow;
  }
}
```

This method processes a chat message using the selected provider and updates the provider's status appropriately.

### Handling Streaming Responses

```dart
// Stream chat responses
Stream<LlmResponseChunk> streamChat(String provider, String message, {bool enableTools = true}) {
  final client = _llmClients[provider];
  if (client == null) {
    throw Exception('Provider $provider not available');
  }

  try {
    _updateProviderStatus(provider, ProviderStatus.processing);

    final responseStream = client.streamChat(
      message,
      enableTools: enableTools,
    );

    // Transform stream to update status when complete
    final transformedStream = responseStream.transform(
        StreamTransformer<LlmResponseChunk, LlmResponseChunk>.fromHandlers(
            handleData: (data, sink) {
              sink.add(data);

              if (data.isDone == true) {
                _updateProviderStatus(provider, ProviderStatus.ready);
              }
            },
            handleError: (error, stackTrace, sink) {
              _updateProviderStatus(provider, ProviderStatus.error, error: error.toString());
              sink.addError(error, stackTrace);
            },
            handleDone: (sink) {
              _updateProviderStatus(provider, ProviderStatus.ready);
              sink.close();
            }
        )
    );

    return transformedStream;
  } catch (e) {
    _updateProviderStatus(provider, ProviderStatus.error, error: error.toString());
    rethrow;
  }
}
```

This method handles streaming responses and updates the provider status on completion or error.

## Runtime Provider Switching

Maintaining MCP connections and context while switching between LLM providers is crucial. Here's how to implement this:

### Setting Up the MCP Client

```dart
// Setup MCP client connection
Future<void> _setupMcpClient(String serverUrl, String? authToken) async {
  try {
    // Create MCP client instance
    _mcpClient = mcp.McpClient.createClient(
      name: 'multi_provider_app',
      version: '1.0.0',
      capabilities: const mcp.ClientCapabilities(
        roots: true,
        rootsListChanged: true,
        sampling: true,
      ),
    );

    // Create transport for MCP connection
    final headers = authToken != null && authToken.isNotEmpty
        ? {'Authorization': 'Bearer $authToken'}
        : null;

    final transport = await mcp.McpClient.createSseTransport(
      serverUrl: serverUrl,
      headers: headers,
    );

    // Setup connection state change event handler
    _mcpClient!.onNotification('connection_state_changed', (params) {
      _updateConnectionState();
    });

    // Connect to MCP server with retry
    await _mcpClient!.connectWithRetry(
      transport,
      maxRetries: 3,
      delay: const Duration(seconds: 2),
    );

    // Update initial connection state
    _updateConnectionState();
  } catch (e) {
    rethrow;
  }
}
```

This method sets up the MCP client and monitors connection state changes.

### Executing Across Multiple Providers

```dart
// Execute query across multiple providers
Future<Map<String, LlmResponse>> executeAcrossProviders(
    String query,
    {
      List<String>? providers,
      bool enableTools = true,
    }
    ) async {
  final targetProviders = providers ?? _llmClients.keys.toList();

  final futures = <String, Future<LlmResponse>>{};
  for (final provider in targetProviders) {
    if (_llmClients.containsKey(provider)) {
      futures[provider] = chat(provider, query, enableTools: enableTools);
    }
  }

  final responses = <String, LlmResponse>{};
  for (final provider in futures.keys) {
    try {
      responses[provider] = await futures[provider]!;
    } catch (_) {
      // Continue with other providers even if one fails
    }
  }

  return responses;
}
```

This method allows you to execute the same query across multiple providers and compare the results.

## Building the MultiProviderManager

To effectively manage multiple LLM providers, we've implemented a `MultiProviderManager` class. This class handles provider registration, status management, and request routing.

### Class Structure

```dart
class MultiProviderManager {
  // Core components
  late McpLlm _mcpLlm;
  mcp.Client? _mcpClient;
  final Map<String, LlmClient> _llmClients = {};

  // State streams
  final _connectionStateController = StreamController<bool>.broadcast();
  final _providerStateController = StreamController<Map<String, ProviderStatus>>.broadcast();
  
  // Provider capabilities
  final Map<String, ProviderCapabilities> _providerCapabilities = {};
  
  // Public access to state streams
  Stream<bool> get connectionState => _connectionStateController.stream;
  Stream<Map<String, ProviderStatus>> get providerStatus => _providerStateController.stream;
  
  // Available providers
  List<String> get availableProviders => _llmClients.keys.toList();
  
  // Constructor
  MultiProviderManager() {
    _mcpLlm = McpLlm();
    _mcpLlm.registerProvider('openai', OpenAiProviderFactory());
    _mcpLlm.registerProvider('claude', ClaudeProviderFactory());
  }
  
  // Additional methods...
}
```

### Initialization and Setup

```dart
// Setup MCP and LLM providers
Future<void> initialize({
  required String mcpServerUrl,
  String? mcpAuthToken,
  String? openaiApiKey,
  String? claudeApiKey,
}) async {
  try {
    // Setup MCP client
    await _setupMcpClient(mcpServerUrl, mcpAuthToken);

    // Setup OpenAI client if API key is provided
    if (openaiApiKey != null && openaiApiKey.isNotEmpty) {
      await _setupLlmClient('openai', openaiApiKey);
    }

    // Setup Claude client if API key is provided
    if (claudeApiKey != null && claudeApiKey.isNotEmpty) {
      await _setupLlmClient('claude', claudeApiKey);
    }

    // Update connection state
    _updateConnectionState();
  } catch (e) {
    rethrow;
  }
}
```

This method initializes the MCP client and sets up LLM clients for each provider with the provided API keys.

### Setting Up LLM Clients for Different Providers

```dart
// Setup LLM client for a provider
Future<void> _setupLlmClient(String providerName, String apiKey) async {
  try {
    // Get default model for the provider
    final model = _getDefaultModel(providerName);

    // Create LLM client with MCP integration
    final llmClient = await _mcpLlm.createClient(
      providerName: providerName,
      config: LlmConfiguration(
        apiKey: apiKey,
        model: model,
        options: {
          'temperature': 0.7,
          'max_tokens': 1500,
        },
      ),
      mcpClient: _mcpClient,
      systemPrompt: 'You are a helpful assistant with access to various tools. Provide concise and accurate responses.',
    );

    // Store the client
    _llmClients[providerName] = llmClient;

    // Store provider capabilities
    _providerCapabilities[providerName] = _assessProviderCapabilities(providerName);

    // Update provider status
    _updateProviderStatus(providerName, ProviderStatus.ready);
  } catch (e) {
    _updateProviderStatus(providerName, ProviderStatus.error, error: e.toString());
  }
}
```

This method sets up an LLM client for a specific provider and assesses its capabilities.

## Smart Provider Selection

Implementing smart routing to automatically select the most appropriate LLM provider based on the query content is a powerful feature:

### Provider Selection Logic

```dart
// Select best provider for a query
String selectProviderForQuery(String query, {Set<String>? requiredCapabilities}) {
  if (_llmClients.isEmpty) {
    throw Exception('No LLM clients available');
  }

  // Code-related queries
  if (query.toLowerCase().contains('code') ||
      query.toLowerCase().contains('programming') ||
      query.toLowerCase().contains('function')) {
    if (_llmClients.containsKey('openai')) {
      return 'openai';
    }
  }

  // Creative content
  if (query.toLowerCase().contains('story') ||
      query.toLowerCase().contains('creative') ||
      query.toLowerCase().contains('write a')) {
    if (_llmClients.containsKey('claude')) {
      return 'claude';
    }
  }

  // Check for required capabilities
  if (requiredCapabilities != null && requiredCapabilities.isNotEmpty) {
    for (final provider in _llmClients.keys) {
      final capabilities = _providerCapabilities[provider];
      if (capabilities == null) continue;

      bool hasAllCapabilities = true;
      for (final capability in requiredCapabilities) {
        if (capabilities.specificCapabilities[capability] != true) {
          hasAllCapabilities = false;
          break;
        }
      }

      if (hasAllCapabilities) {
        return provider;
      }
    }
  }

  // Default to ready provider from current status
  for (final provider in _llmClients.keys) {
    if (_providerStatus[provider] == ProviderStatus.ready) {
      return provider;
    }
  }

  // Fallback to first provider
  return _llmClients.keys.first;
}
```

This method analyzes the query content and required capabilities to select the optimal provider.

### Smart Execution Implementation

```dart
// Auto-select provider and execute query
Future<ProviderResponse> smartExecute(
    String query,
    {
      Set<String>? requiredCapabilities,
      bool enableTools = true,
    }
    ) async {
  final provider = selectProviderForQuery(query, requiredCapabilities: requiredCapabilities);

  try {
    final response = await chat(provider, query, enableTools: enableTools);
    return ProviderResponse(
      provider: provider,
      response: response,
      error: null,
    );
  } catch (e) {
    return ProviderResponse(
      provider: provider,
      response: null,
      error: e.toString(),
    );
  }
}
```

This method automatically selects the best provider and executes the query.

## Creating a Multi-Provider User Interface

Let's implement a UI that integrates multiple LLM providers, allowing users to select providers, compare responses, and view real-time status:

### Multi-Provider Chat Screen

```dart
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
      // Manager setup and initialization
      // ...
    } catch (e) {
      // Error handling
      // ...
    }
  }

  // Handle message sending
  void _sendMessage(String text) async {
    if (text.trim().isEmpty) return;

    // Various message handling methods
    // ...
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Multi-Provider AI Chat'),
        actions: [
          // Provider selector dropdown
          // ...
          // MCP connection status indicator
          // ...
        ],
      ),
      body: Column(
        children: [
          // Message list
          // ...
          // Progress indicator
          // ...
          // Text input
          // ...
        ],
      ),
    );
  }
}
```

This screen interacts with multiple LLM providers, displays status visually, and handles various commands.

### Provider Status Display

```dart
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
```

This dropdown displays the list of available providers and their current status with visual indicators.

### Command Handling

The UI handles special commands:

- `/provider [name]`: Switch to a specific provider
- `/compare [query]`: Execute the same query across multiple providers and compare results
- `/stream [query]`: Enable streaming responses
- `/smart [query]`: Auto-select provider and execute

## Use Cases and Examples

Let's explore some example use cases for the MultiProviderManager:

### 1. Provider Comparison

```dart
// Compare providers
void _compareProviders(String text) async {
  try {
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
    // Error handling
  }
}
```

### 2. Smart Provider Selection

```dart
// Auto-select best provider and execute
void _smartExecute(String text) async {
  try {
    setState(() {
      _isLoading = true;
    });

    final result = await _providerManager.smartExecute(text);

    setState(() {
      _isLoading = false;

      if (result.isSuccess) {
        _messages.add(ChatMessage(
          text: result.response!.text,
          isUser: false,
          providerName: result.provider,
          toolCalls: result.response!.toolCalls,
          isAutoSelected: true,
        ));
      } else {
        _messages.add(ChatMessage(
          text: 'Error with provider ${result.provider}: ${result.error}',
          isUser: false,
          isError: true,
        ));
      }
    });
  } catch (e) {
    // Error handling
  }
}
```

## Next Steps

In this article, we've explored integrating multiple LLM providers with the MCP ecosystem. Building on this foundation, you can explore these advanced topics:

1. **Extending MCP Ecosystem with Plugins**: Develop custom tools and resources as plugins
2. **Building and Managing Multi-MCP Environments**: Design distributed environments with multiple MCP clients/servers
3. **Parallel Processing in MCP-LLM Integration**: Implement parallel task execution with MCP tools
4. **Building RAG Systems with MCP Integration**: Create knowledge-based systems with document retrieval

## Conclusion

Integrating multiple LLM providers with the MCP ecosystem allows you to leverage the strengths of each provider while maintaining a consistent development experience. Using the `MultiProviderManager` class, you can effectively manage multiple providers, select the optimal provider based on the query content, and maintain MCP connections during provider switches.

By implementing these patterns in your Flutter application, you can deliver diverse AI capabilities while managing code complexity. The Model Context Protocol serves as the cornerstone of this integration, providing a standardized interface across different providers.

In the next article, we'll explore building and extending the MCP plugin system to further enhance your AI applications.

---

## Resources

- [Multi-Provider MCP Sample Code](https://github.com/MCP-Dev-Studio/multi_provider_integration)
- [mcp_llm GitHub Repository](https://github.com/app-appplayer/mcp_llm)
- [mcp_client GitHub Repository](https://github.com/app-appplayer/mcp_client)
- [Model Context Protocol](https://modelcontextprotocol.io/)
- [OpenAI API Documentation](https://platform.openai.com/docs/)
- [Claude API Documentation](https://docs.anthropic.com/claude/reference/)
- [Flutter Documentation](https://flutter.dev/docs)

---

### Support the Developer

If you found this article helpful, please consider supporting the development of more free content through Patreon. Your support makes a big difference!

[![Support on Patreon](https://c5.patreon.com/external/logo/become_a_patron_button.png)](https://www.patreon.com/mcpdevstudio)

**Tags**: #Flutter #AI #MCP #LLM #Dart #OpenAI #Claude #ModelContextProtocol #AIIntegration #MultiProvider