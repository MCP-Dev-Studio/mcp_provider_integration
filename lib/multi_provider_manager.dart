// multi_provider_integration.dart
// Core integration file for multiple LLM providers with MCP

import 'dart:async';
import 'package:mcp_llm/mcp_llm.dart';
import 'package:mcp_client/mcp_client.dart' as mcp;

/// Manager for integrating multiple LLM providers with MCP
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

  // Connection status
  bool get isConnected => _mcpClient != null && _mcpClient!.isConnected;

  // Available providers
  List<String> get availableProviders => _llmClients.keys.toList();

  // Initialize with OpenAI and Claude providers
  MultiProviderManager() {
    _mcpLlm = McpLlm();
    _mcpLlm.registerProvider('openai', OpenAiProviderFactory());
    _mcpLlm.registerProvider('claude', ClaudeProviderFactory());
  }

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

  // Get default model for a provider
  String _getDefaultModel(String providerName) {
    switch (providerName.toLowerCase()) {
      case 'openai':
        return 'gpt-4o';
      case 'claude':
        return 'claude-3-haiku-20240307';
      default:
        throw Exception('Unknown provider: $providerName');
    }
  }

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

  // Get maximum context length for a provider
  int _getMaxContextLength(String providerName) {
    switch (providerName.toLowerCase()) {
      case 'openai':
        return 128000; // GPT-4o
      case 'claude':
        return 200000; // Claude 3
      default:
        return 8000;
    }
  }

  // Update connection state
  void _updateConnectionState() {
    _connectionStateController.add(isConnected);
  }

  // Update provider status
  void _updateProviderStatus(String provider, ProviderStatus status, {String? error}) {
    Map<String, ProviderStatus> currentStatus = {};

    // Create a new map with current status
    for (final key in _providerStatus.keys) {
      currentStatus[key] = _providerStatus[key]!;
    }

    // Update the status for this provider
    currentStatus[provider] = status;

    // Store the updated status internally too
    _providerStatus = currentStatus;

    // Notify listeners
    _providerStateController.add(currentStatus);
  }

  // Store current provider status
  Map<String, ProviderStatus> _providerStatus = {};

  // Get provider capabilities
  ProviderCapabilities? getProviderCapabilities(String providerName) {
    return _providerCapabilities[providerName];
  }

  // Check if provider supports a specific capability
  bool providerSupports(String providerName, String capability) {
    final capabilities = _providerCapabilities[providerName];
    if (capabilities == null) return false;

    return capabilities.specificCapabilities[capability] == true;
  }

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
      _updateProviderStatus(provider, ProviderStatus.error, error: e.toString());
      rethrow;
    }
  }

  // Execute tool
  Future<dynamic> executeTool(String provider, String toolName, Map<String, dynamic> arguments) async {
    final client = _llmClients[provider];
    if (client == null) {
      throw Exception('Provider $provider not available');
    }

    try {
      _updateProviderStatus(provider, ProviderStatus.processing);

      final result = await client.executeTool(
        toolName,
        arguments,
      );

      _updateProviderStatus(provider, ProviderStatus.ready);
      return result;
    } catch (e) {
      _updateProviderStatus(provider, ProviderStatus.error, error: e.toString());
      rethrow;
    }
  }

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

  // Get available MCP tools
  Future<List<mcp.Tool>> getAvailableTools() async {
    if (_mcpClient == null || !isConnected) {
      throw Exception('MCP client is not connected');
    }

    return await _mcpClient!.listTools();
  }

  // Get resource from MCP server
  Future<dynamic> getResource(String resourceName) async {
    if (_mcpClient == null || !isConnected) {
      throw Exception('MCP client is not connected');
    }

    return await _mcpClient!.readResource(resourceName);
  }

  // Clean up resources
  Future<void> dispose() async {
    await _mcpLlm.shutdown();
    _connectionStateController.close();
    _providerStateController.close();
  }
}

// Provider status enum
enum ProviderStatus {
  unknown,
  initializing,
  ready,
  processing,
  error,
}

// Provider capabilities class
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

// Provider response class
class ProviderResponse {
  final String provider;
  final LlmResponse? response;
  final String? error;

  ProviderResponse({
    required this.provider,
    required this.response,
    required this.error,
  });

  bool get isSuccess => response != null && error == null;
}

// Helper function - min
int min(int a, int b) => a < b ? a : b;