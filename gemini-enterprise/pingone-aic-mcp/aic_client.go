package main

import (
	"bytes"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

var (
	aicBaseURL         string
	aicAdminClientID   string
	aicAdminPrivateKey *rsa.PrivateKey
	aicRealm           string
)

var tokenCache struct {
	mu        sync.Mutex
	token     string
	expiresAt time.Time
}

func getAdminToken() (string, error) {
	tokenCache.mu.Lock()
	defer tokenCache.mu.Unlock()
	if tokenCache.token != "" && time.Now().Before(tokenCache.expiresAt.Add(-60*time.Second)) {
		return tokenCache.token, nil
	}
	token, expiresIn, err := fetchAdminToken()
	if err != nil {
		return "", err
	}
	tokenCache.token = token
	tokenCache.expiresAt = time.Now().Add(time.Duration(expiresIn) * time.Second)
	log.Printf("aic: new token expires_in=%ds", expiresIn)
	return token, nil
}

func fetchAdminToken() (string, int, error) {
	tokenURL := fmt.Sprintf("%s/am/oauth2/access_token", aicBaseURL)
	assertion, err := buildAssertion(tokenURL)
	if err != nil {
		return "", 0, fmt.Errorf("build assertion: %w", err)
	}
	form := url.Values{
		"client_id":  {"service-account"},
		"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"},
		"assertion":  {assertion},
		"scope":      {"fr:idm:*"},
	}
	req, _ := http.NewRequest(http.MethodPost, tokenURL, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", 0, fmt.Errorf("token request: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return "", 0, fmt.Errorf("token endpoint %d: %s", resp.StatusCode, body)
	}
	var result struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.Unmarshal(body, &result); err != nil || result.AccessToken == "" {
		return "", 0, fmt.Errorf("parse token response: %w body=%s", err, body)
	}
	return result.AccessToken, result.ExpiresIn, nil
}

func buildAssertion(audience string) (string, error) {
	now := time.Now()
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, jwt.MapClaims{
		"iss": aicAdminClientID,
		"sub": aicAdminClientID,
		"aud": audience,
		"exp": now.Add(15 * time.Minute).Unix(),
		"jti": uuid.NewString(),
	})
	return tok.SignedString(aicAdminPrivateKey)
}

func loadRSAPrivateKeyFromJWK(jwkJSON string) (*rsa.PrivateKey, error) {
	var k struct {
		N, E, D, P, Q, Dp, Dq, Qi string
	}
	if err := json.Unmarshal([]byte(jwkJSON), &k); err != nil {
		return nil, fmt.Errorf("parse JWK: %w", err)
	}
	dec := func(s string) *big.Int {
		b, _ := base64.RawURLEncoding.DecodeString(s)
		return new(big.Int).SetBytes(b)
	}
	eBytes, _ := base64.RawURLEncoding.DecodeString(k.E)
	eInt := 0
	for _, b := range eBytes {
		eInt = eInt<<8 | int(b)
	}
	priv := &rsa.PrivateKey{
		PublicKey: rsa.PublicKey{N: dec(k.N), E: eInt},
		D:         dec(k.D),
		Primes:    []*big.Int{dec(k.P), dec(k.Q)},
	}
	priv.Precomputed.Dp = dec(k.Dp)
	priv.Precomputed.Dq = dec(k.Dq)
	priv.Precomputed.Qinv = dec(k.Qi)
	if err := priv.Validate(); err != nil {
		return nil, fmt.Errorf("invalid RSA key: %w", err)
	}
	return priv, nil
}

func managedUserURL() string {
	return fmt.Sprintf("%s/openidm/managed/%s_user", aicBaseURL, aicRealm)
}

func aicRequest(method, url string, payload any) ([]byte, int, error) {
	token, err := getAdminToken()
	if err != nil {
		return nil, 0, fmt.Errorf("get admin token: %w", err)
	}
	var bodyReader io.Reader
	if payload != nil {
		encoded, err := json.Marshal(payload)
		if err != nil {
			return nil, 0, err
		}
		bodyReader = bytes.NewReader(encoded)
	}
	req, _ := http.NewRequest(method, url, bodyReader)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/json")
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return body, resp.StatusCode, nil
}

func CreateAicUser(username, email, firstName, lastName, password string) (string, error) {
	body, status, err := aicRequest(http.MethodPost, managedUserURL(), map[string]string{
		"userName": username, "mail": email, "givenName": firstName,
		"sn": lastName, "userPassword": password, "accountStatus": "active",
	})
	if err != nil || status < 200 || status >= 300 {
		return "", fmt.Errorf("create user returned %d: %s", status, body)
	}
	var result struct {
		ID       string `json:"_id"`
		UserName string `json:"userName"`
		Mail     string `json:"mail"`
	}
	json.Unmarshal(body, &result)
	return fmt.Sprintf("user_id=%s username=%s email=%s", result.ID, result.UserName, result.Mail), nil
}

func DeleteAicUser(email string) (string, error) {
	id, err := lookupUserIDByEmail(email)
	if err != nil {
		return "", err
	}
	body, status, err := aicRequest(http.MethodDelete, managedUserURL()+"/"+id, nil)
	if err != nil || status < 200 || status >= 300 {
		return "", fmt.Errorf("delete user returned %d: %s", status, body)
	}
	return fmt.Sprintf("deleted user_id=%s email=%s", id, email), nil
}

func UpdateAicUserStatus(email string, enabled bool) (string, error) {
	id, err := lookupUserIDByEmail(email)
	if err != nil {
		return "", err
	}
	accountStatus := "active"
	if !enabled {
		accountStatus = "inactive"
	}
	body, status, err := aicRequest(http.MethodPatch, managedUserURL()+"/"+id, map[string]string{"accountStatus": accountStatus})
	if err != nil || status < 200 || status >= 300 {
		return "", fmt.Errorf("update user returned %d: %s", status, body)
	}
	return fmt.Sprintf("updated user_id=%s email=%s accountStatus=%s", id, email, accountStatus), nil
}

func ListAicUsers(filter string) (string, error) {
	if filter == "" {
		filter = "true"
	}
	queryURL := managedUserURL() + "?_queryFilter=" + url.QueryEscape(filter) + "&_fields=_id,userName,mail,givenName,sn"
	body, status, err := aicRequest(http.MethodGet, queryURL, nil)
	if err != nil || status < 200 || status >= 300 {
		return "", fmt.Errorf("list users returned %d: %s", status, body)
	}
	var result struct {
		Result []struct {
			ID        string `json:"_id"`
			UserName  string `json:"userName"`
			Mail      string `json:"mail"`
			GivenName string `json:"givenName"`
			Sn        string `json:"sn"`
		} `json:"result"`
	}
	json.Unmarshal(body, &result)
	if len(result.Result) == 0 {
		return "no users found", nil
	}
	lines := make([]string, len(result.Result))
	for i, u := range result.Result {
		lines[i] = fmt.Sprintf("id=%s username=%s email=%s givenName=%s sn=%s", u.ID, u.UserName, u.Mail, u.GivenName, u.Sn)
	}
	return strings.Join(lines, "\n"), nil
}

func lookupUserIDByEmail(email string) (string, error) {
	queryURL := managedUserURL() + "?_queryFilter=mail+eq+%22" + url.QueryEscape(email) + "%22&_fields=_id"
	body, status, err := aicRequest(http.MethodGet, queryURL, nil)
	if err != nil || status != http.StatusOK {
		return "", fmt.Errorf("user lookup returned %d: %s", status, body)
	}
	var result struct {
		Result []struct {
			ID string `json:"_id"`
		} `json:"result"`
	}
	json.Unmarshal(body, &result)
	if len(result.Result) == 0 {
		return "", fmt.Errorf("no user found with email=%s", email)
	}
	return result.Result[0].ID, nil
}
