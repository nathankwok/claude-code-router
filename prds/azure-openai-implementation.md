# Azure OpenAI Integration - Product Requirements Document

## Executive Summary

This PRD outlines the implementation of Azure OpenAI support for the Claude Code Router. Azure OpenAI provides enterprise-grade AI capabilities with enhanced security, compliance, and regional availability. This feature will enable users to route requests to Azure OpenAI deployments alongside existing OpenAI and other LLM providers.

## Background & Context

### Current Architecture
The Claude Code Router currently supports multiple LLM providers through a unified configuration system:
- **Provider-based architecture**: Each provider has name, api_base_url, api_key, and models
- **Transformer system**: Configurable request/response transformations at provider and model levels
- **Middleware pipeline**: rewriteBody → router → formatRequest → OpenAI API call
- **Caching**: LRU cache for provider instances with 2-hour TTL

### Why Azure OpenAI?
Azure OpenAI Service offers:
- Enhanced security and compliance (SOC 2, GDPR, HIPAA)
- Regional data residency
- Private networking capabilities
- Enterprise-grade SLAs
- Integration with Azure services

## Technical Requirements

### Azure OpenAI API Specifics
Azure OpenAI differs from standard OpenAI in several key ways:

1. **URL Structure**:
   ```
   Standard OpenAI: https://api.openai.com/v1/chat/completions
   Azure OpenAI: https://{resource}.openai.azure.com/openai/deployments/{deployment}/chat/completions?api-version={api-version}
   ```

2. **Required Parameters**:
   - `resource`: Azure OpenAI resource name
   - `deployment`: Model deployment name (user-defined)
   - `api-version`: Azure API version (e.g., "2024-12-01-preview")

3. **Authentication**: Uses `api-key` header instead of `Authorization: Bearer`

4. **Model Mapping**: Uses deployment names instead of standard model names

5. **API Versions**: Different versions support different features
   - `2024-12-01-preview`: Latest with reasoning models (o1, o3-mini)
   - `2024-07-18`: Stable with GPT-4o support
   - `2023-05-15`: Legacy version

## Implementation Phases

### Phase 1: Core Azure OpenAI Provider Support
**Objective**: Implement basic Azure OpenAI provider functionality  
**Timeline**: 3-5 days

#### Tasks:
1. **Extend ModelProvider Interface**
   - Add optional Azure-specific fields to ModelProvider interface
   - Fields: `resource?`, `deployment?`, `apiVersion?`, `providerType?`
   - File: `src/index.ts`

2. **Create Azure Provider Detection Logic**
   - Detect Azure providers by URL pattern or explicit type
   - Function to identify if provider is Azure OpenAI
   - Location: `src/utils/azure.ts` (new file)

3. **Implement Azure URL Construction**
   - Build Azure OpenAI URLs with resource, deployment, and API version
   - Handle query parameter injection
   - Validate required parameters

4. **Update Provider Instance Creation**
   - Modify `getProviderInstance` in `src/index.ts`
   - Handle Azure-specific OpenAI client configuration
   - Set appropriate baseURL and headers

5. **Add Azure Authentication Headers**
   - Set `api-key` header for Azure providers
   - Maintain compatibility with standard OpenAI Bearer tokens

#### Acceptance Criteria:
- [ ] Azure providers can be detected from configuration
- [ ] Azure OpenAI URLs are constructed correctly
- [ ] API key authentication works for Azure endpoints
- [ ] Standard OpenAI providers remain unaffected

---

### Phase 2: Configuration Schema Updates
**Objective**: Extend configuration system to support Azure OpenAI parameters  
**Timeline**: 2-3 days

#### Tasks:
1. **Update Configuration Types**
   - Extend existing provider types with Azure fields
   - Add validation for Azure-specific required fields
   - File: Update interface definitions

2. **Add Configuration Validation**
   - Validate required Azure fields (resource, deployment, apiVersion)
   - Provide helpful error messages for missing parameters
   - Location: `src/utils/validation.ts` (new file)

3. **Update Configuration Examples**
   - Add Azure OpenAI examples to `config.example.json`
   - Include common deployment patterns
   - Document parameter meanings

4. **Backward Compatibility**
   - Ensure existing configurations continue working
   - Optional Azure fields don't break non-Azure providers
   - Migration path for existing users

5. **Environment Variable Support**
   - Support Azure configuration via environment variables
   - `AZURE_OPENAI_RESOURCE`, `AZURE_OPENAI_DEPLOYMENT`, etc.

#### Acceptance Criteria:
- [ ] Azure configuration validates properly
- [ ] Helpful error messages for invalid config
- [ ] Existing configurations remain valid
- [ ] Environment variables work for Azure settings

---

### Phase 3: Request/Response Transformation
**Objective**: Handle Azure-specific request/response formatting  
**Timeline**: 3-4 days

#### Tasks:
1. **Create Azure URL Transformer**
   - Transform base URLs to Azure format
   - Inject deployment names and API versions
   - Handle regional endpoints

2. **Implement Model-to-Deployment Mapping**
   - Map standard model names to Azure deployments
   - Support custom deployment naming
   - Handle multiple deployments per model

3. **Azure API Version Management**
   - Inject API version as query parameter
   - Support version-specific features
   - Handle version compatibility

4. **Error Response Handling**
   - Transform Azure error responses to standard format
   - Handle Azure-specific error codes
   - Maintain error message consistency

5. **Rate Limiting Considerations**
   - Handle Azure-specific rate limiting headers
   - Implement retry logic for throttling
   - Support quota management

#### Acceptance Criteria:
- [ ] Requests are properly formatted for Azure
- [ ] Model names map to deployments correctly
- [ ] API versions are handled appropriately
- [ ] Error responses are standardized

---

### Phase 4: Integration and Middleware Updates
**Objective**: Integrate Azure support with existing middleware pipeline  
**Timeline**: 2-3 days

#### Tasks:
1. **Update Router Middleware**
   - Ensure Azure providers work with routing logic
   - Handle Azure-specific model selection
   - File: `src/middlewares/router.ts`

2. **Modify Format Request Middleware**
   - Handle Azure-specific request formatting if needed
   - Ensure tool calls work with Azure
   - File: `src/middlewares/formatRequest.ts`

3. **Update Provider Cache Logic**
   - Cache Azure provider instances appropriately
   - Handle different cache keys for Azure providers
   - Include deployment info in cache keys

4. **Enhanced Error Handling**
   - Azure-specific error codes and messages
   - Debugging support for Azure endpoints
   - Comprehensive logging

5. **Request/Response Logging**
   - Log Azure-specific parameters
   - Include deployment and resource info in logs
   - Support debugging Azure connectivity issues

#### Acceptance Criteria:
- [ ] Azure providers work with existing middleware
- [ ] Provider caching works correctly
- [ ] Error handling is comprehensive
- [ ] Logging provides useful debugging info

---

### Phase 5: Documentation and User Experience
**Objective**: Provide comprehensive documentation and examples  
**Timeline**: 2-3 days

#### Tasks:
1. **Configuration Guide**
   - Step-by-step Azure OpenAI setup
   - Common deployment patterns
   - Troubleshooting guide

2. **API Reference Documentation**
   - Azure-specific configuration options
   - Parameter descriptions and examples
   - Version compatibility matrix

3. **Migration Examples**
   - Converting from OpenAI to Azure OpenAI
   - Side-by-side configuration examples
   - Best practices and recommendations

4. **Error Troubleshooting**
   - Common Azure OpenAI errors
   - Resolution steps
   - Debugging checklist

5. **Update README**
   - Add Azure OpenAI to supported providers list
   - Include quick start example
   - Link to detailed documentation

#### Acceptance Criteria:
- [ ] Complete setup documentation available
- [ ] Migration examples provided
- [ ] Troubleshooting guide comprehensive
- [ ] README updated with Azure support

---

## Phase Summary
**Total Estimated Time**: 12-18 days

| Phase | Timeline | Focus |
|-------|----------|-------|
| Phase 1 | 3-5 days | Core functionality |
| Phase 2 | 2-3 days | Configuration updates |
| Phase 3 | 3-4 days | Transformations |
| Phase 4 | 2-3 days | Integration |
| Phase 5 | 2-3 days | Documentation |

## Technical Specifications

### Configuration Schema

```typescript
interface ModelProvider {
  name: string;
  api_base_url: string;
  api_key: string;
  models: string[];
  
  // Azure OpenAI specific fields
  resource?: string;           // Azure resource name
  deployment?: string;         // Default deployment name
  apiVersion?: string;         // Azure API version
  providerType?: 'azure-openai' | 'openai' | string;
  
  // Model-specific deployments
  deployments?: {
    [modelName: string]: string;  // model -> deployment mapping
  };
}
```

### Configuration Example

```json
{
  "Providers": [
    {
      "name": "azure-openai-prod",
      "api_base_url": "https://my-resource.openai.azure.com",
      "api_key": "your-azure-api-key",
      "resource": "my-resource",
      "apiVersion": "2024-12-01-preview",
      "providerType": "azure-openai",
      "models": ["gpt-4o", "gpt-4o-mini", "o1-preview"],
      "deployments": {
        "gpt-4o": "gpt-4o-deployment",
        "gpt-4o-mini": "gpt-4o-mini-deployment",
        "o1-preview": "o1-preview-deployment"
      },
      "transformer": {
        "use": ["azure-openai"]
      }
    }
  ]
}
```

### Azure URL Construction Logic

```typescript
function buildAzureOpenAIUrl(provider: ModelProvider, model: string): string {
  const { resource, deployments, apiVersion } = provider;
  const deployment = deployments?.[model] || model;
  const baseUrl = `https://${resource}.openai.azure.com`;
  return `${baseUrl}/openai/deployments/${deployment}/chat/completions?api-version=${apiVersion}`;
}
```

### Required File Changes

1. **src/index.ts**
   - Update `ModelProvider` interface
   - Modify `getProviderInstance` function
   - Add Azure detection logic

2. **src/utils/azure.ts** (new file)
   - Azure URL construction
   - Provider detection utilities
   - Deployment mapping logic

3. **src/middlewares/router.ts**
   - Handle Azure model routing
   - Support deployment-based routing

4. **config.example.json**
   - Add Azure OpenAI examples
   - Document configuration options

5. **package.json**
   - No new dependencies required (uses existing OpenAI SDK)

## Testing & Validation

### Unit Tests
- Azure URL construction
- Provider detection logic
- Configuration validation
- Model-to-deployment mapping

### Integration Tests
- Full request/response cycle
- Middleware pipeline with Azure providers
- Error handling scenarios
- Cache behavior verification

### Manual Testing Checklist
- [ ] Azure OpenAI requests complete successfully
- [ ] Standard OpenAI providers still work
- [ ] Error messages are helpful
- [ ] Configuration validation works
- [ ] Provider caching functions correctly
- [ ] Logging provides useful information

### Test Configuration

```json
{
  "name": "azure-openai-test",
  "api_base_url": "https://test-resource.openai.azure.com",
  "api_key": "test-key",
  "resource": "test-resource",
  "apiVersion": "2024-12-01-preview",
  "providerType": "azure-openai",
  "models": ["gpt-4o"],
  "deployments": {
    "gpt-4o": "test-gpt-4o-deployment"
  }
}
```

## Risk Assessment & Mitigation

### Technical Risks
1. **Backward Compatibility**: Risk of breaking existing configurations
   - **Mitigation**: Extensive testing, gradual rollout, optional fields

2. **API Version Management**: Azure API versions change frequently
   - **Mitigation**: Support multiple versions, clear documentation

3. **URL Construction Complexity**: Azure URLs are more complex
   - **Mitigation**: Comprehensive validation, helpful error messages

### Operational Risks
1. **Configuration Complexity**: Azure requires more parameters
   - **Mitigation**: Clear documentation, validation, examples

2. **Debugging Difficulty**: More complex error scenarios
   - **Mitigation**: Enhanced logging, troubleshooting guides

## Success Metrics

- [ ] Azure OpenAI providers can be configured successfully
- [ ] Requests route correctly to Azure deployments
- [ ] Performance matches existing OpenAI providers
- [ ] Error handling provides clear guidance
- [ ] Documentation enables self-service setup
- [ ] No regression in existing provider functionality

## Timeline Estimate

- **Phase 1**: 3-5 days (Core functionality)
- **Phase 2**: 2-3 days (Configuration updates)
- **Phase 3**: 3-4 days (Transformations)
- **Phase 4**: 2-3 days (Integration)
- **Phase 5**: 2-3 days (Documentation)

**Total Estimated Time**: 12-18 days

## Implementation Notes

### Development Environment Setup
1. Create Azure OpenAI resource for testing
2. Set up test deployments
3. Configure local environment variables

### Key Implementation Points
- Reuse existing OpenAI SDK with Azure base URLs
- Maintain existing transformer architecture
- Preserve provider caching behavior
- Ensure comprehensive error handling

### Potential Extensions
- Azure Active Directory authentication
- Azure Key Vault integration
- Multi-region support
- Deployment health monitoring

This PRD provides comprehensive guidance for implementing Azure OpenAI support in the Claude Code Router. The phased approach ensures systematic implementation while maintaining backward compatibility and code quality.