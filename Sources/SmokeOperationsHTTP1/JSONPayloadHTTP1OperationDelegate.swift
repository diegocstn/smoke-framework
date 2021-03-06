// Copyright 2018-2019 Amazon.com, Inc. or its affiliates. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// You may not use this file except in compliance with the License.
// A copy of the License is located at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// or in the "license" file accompanying this file. This file is distributed
// on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
// express or implied. See the License for the specific language governing
// permissions and limitations under the License.
//
//  JSONPayloadHTTP1OperationDelegate.swift
//  SmokeOperationsHTTP1
//

import Foundation
import SmokeOperations
import SmokeHTTP1
import LoggerAPI
import HTTPPathCoding
import HTTPHeadersCoding
import QueryCoding

internal struct MimeTypes {
    static let json = "application/json"
}

internal struct JSONErrorEncoder: ErrorEncoder {
    public func encode<InputType>(_ input: InputType) throws -> Data where InputType: SmokeReturnableError {
        return JSONEncoder.encodePayload(payload: input,
                                         reason: input.description)
    }
}

/**
 Struct conforming to the OperationDelegate protocol that handles operations from HTTP1 requests with JSON encoded
 request and response payloads.
 */
public struct JSONPayloadHTTP1OperationDelegate: HTTP1OperationDelegate {
    public init() {
        
    }
    
    public func getInputForOperation<InputType: OperationHTTP1InputProtocol>(request: SmokeHTTP1Request) throws -> InputType {
        
        func queryDecodableProvider() throws -> InputType.QueryType {
            return try QueryDecoder().decode(InputType.QueryType.self,
                                             from: request.query)
        }
        
        func pathDecodableProvider() throws -> InputType.PathType {
            return try HTTPPathDecoder().decode(InputType.PathType.self,
                                                fromShape: request.pathShape)
        }
        
        func bodyDecodableProvider() throws -> InputType.BodyType {
            if let body = request.body {
                return try JSONDecoder.getFrameworkDecoder().decode(InputType.BodyType.self, from: body)
            } else {
                throw SmokeOperationsError.validationError(reason: "Input body expected; none found.")
            }
        }
        
        func headersDecodableProvider() throws -> InputType.HeadersType {
            let headers: [(String, String?)] =
                request.httpRequestHead.headers.map { header in
                    return (header.name, header.value)
            }
            return try HTTPHeadersDecoder().decode(InputType.HeadersType.self,
                                                   from: headers)
        }
        
        return try InputType.compose(queryDecodableProvider: queryDecodableProvider,
                                     pathDecodableProvider: pathDecodableProvider,
                                     bodyDecodableProvider: bodyDecodableProvider,
                                     headersDecodableProvider: headersDecodableProvider)
    }
    
    public func getInputForOperation<InputType>(request: SmokeHTTP1Request,
                                                location: OperationInputHTTPLocation) throws
        -> InputType where InputType: Decodable {
        
            switch location {
            case .body:
                let wrappedInput: BodyOperationHTTPInput<InputType> =
                    try getInputForOperation(request: request)
                
                return wrappedInput.body
            case .query:
                let wrappedInput: QueryOperationHTTPInput<InputType> =
                    try getInputForOperation(request: request)
                
                return wrappedInput.query
            case .path:
                let wrappedInput: PathOperationHTTPInput<InputType> =
                    try getInputForOperation(request: request)
                
                return wrappedInput.path
            case .headers:
                let wrappedInput: HeadersOperationHTTPInput<InputType> =
                    try getInputForOperation(request: request)
                
                return wrappedInput.headers
            }
    }
    
    public func handleResponseForOperation<OutputType>(request: SmokeHTTP1Request, output: OutputType,
                                                       responseHandler: HTTP1ResponseHandler) where OutputType: OperationHTTP1OutputProtocol {
        let body: (contentType: String, data: Data)?
        
        if let bodyEncodable = output.bodyEncodable {
            let encodedOutput: Data
            do {
                encodedOutput = try JSONEncoder.getFrameworkEncoder().encode(bodyEncodable)
            } catch {
                Log.error("Serialization error: unable to encode response: \(error)")
                
                handleResponseForInternalServerError(request: request, responseHandler: responseHandler)
                return
            }
            
            body = (contentType: MimeTypes.json, data: encodedOutput)
        } else {
            body = nil
        }
        
        let additionalHeaders: [(String, String)]
        if let additionalHeadersEncodable = output.additionalHeadersEncodable {
            let headers: [(String, String?)]
            do {
                headers = try HTTPHeadersEncoder().encode(additionalHeadersEncodable)
            } catch {
                Log.error("Serialization error: unable to encode response: \(error)")
                
                handleResponseForInternalServerError(request: request, responseHandler: responseHandler)
                return
            }
            
            additionalHeaders = headers.compactMap { header in
                guard let value = header.1 else {
                    return nil
                }
                
                return (header.0, value)
            }
        } else {
            additionalHeaders = []
        }
        
        let responseComponents = HTTP1ServerResponseComponents(
            additionalHeaders: additionalHeaders,
            body: body)
        
        responseHandler.complete(status: .ok, responseComponents: responseComponents)
    }
    
    public func handleResponseForOperation<OutputType>(
            request: SmokeHTTP1Request,
            location: OperationOutputHTTPLocation,
            output: OutputType,
            responseHandler: HTTP1ResponseHandler) where OutputType: Encodable {
        switch location {
        case .body:
            let wrappedOutput = BodyOperationHTTPOutput<OutputType>(
                bodyEncodable: output)
            
            handleResponseForOperation(request: request,
                                       output: wrappedOutput,
                                       responseHandler: responseHandler)
        case .headers:
            let wrappedOutput = AdditionalHeadersOperationHTTPOutput<OutputType>(
                additionalHeadersEncodable: output)
            
            handleResponseForOperation(request: request,
                                       output: wrappedOutput,
                                       responseHandler: responseHandler)
        }
    }
    
    public func handleResponseForOperationWithNoOutput(request: SmokeHTTP1Request,
                                                       responseHandler: HTTP1ResponseHandler) {
        let responseComponents = HTTP1ServerResponseComponents(additionalHeaders: [], body: nil)
        responseHandler.complete(status: .ok, responseComponents: responseComponents)
    }
    
    public func handleResponseForOperationFailure(request: SmokeHTTP1Request,
                                                  operationFailure: OperationFailure,
                                                  responseHandler: HTTP1ResponseHandler) {
        let encodedOutput: Data
        
        do {
            encodedOutput = try operationFailure.error.encode(errorEncoder: JSONErrorEncoder())
        } catch {
            Log.error("Serialization error: unable to encode response: \(error)")
            
            handleResponseForInternalServerError(request: request, responseHandler: responseHandler)
            return
        }
        
        let body = (contentType: MimeTypes.json, data: encodedOutput)
        let responseComponents = HTTP1ServerResponseComponents(additionalHeaders: [], body: body)

        responseHandler.complete(status: .custom(code: UInt(operationFailure.code), reasonPhrase: operationFailure.error.description),
                                 responseComponents: responseComponents)
    }
    
    public func handleResponseForInternalServerError(request: SmokeHTTP1Request,
                                                     responseHandler: HTTP1ResponseHandler) {
        handleError(code: 500, reason: "InternalError", message: nil, responseHandler: responseHandler)
    }
    
    public func handleResponseForInvalidOperation(request: SmokeHTTP1Request,
                                                  message: String, responseHandler: HTTP1ResponseHandler) {
        handleError(code: 400, reason: "InvalidOperation", message: message, responseHandler: responseHandler)
    }
    
    public func handleResponseForDecodingError(request: SmokeHTTP1Request,
                                               message: String, responseHandler: HTTP1ResponseHandler) {
        handleError(code: 400, reason: "DecodingError", message: message, responseHandler: responseHandler)
    }
    
    public func handleResponseForValidationError(request: SmokeHTTP1Request,
                                                 message: String?, responseHandler: HTTP1ResponseHandler) {
        handleError(code: 400, reason: "ValidationError", message: message, responseHandler: responseHandler)
    }
    
    internal func handleError(code: Int,
                              reason: String,
                              message: String?,
                              responseHandler: HTTP1ResponseHandler) {
        let errorResult = SmokeOperationsErrorPayload(errorMessage: message)
        let encodedError = JSONEncoder.encodePayload(payload: errorResult,
                                                     reason: reason)
        
        let body = (contentType: MimeTypes.json, data: encodedError)
        let responseComponents = HTTP1ServerResponseComponents(additionalHeaders: [], body: body)

        responseHandler.complete(status: .custom(code: UInt(code), reasonPhrase: reason),
                                 responseComponents: responseComponents)
    }
}
